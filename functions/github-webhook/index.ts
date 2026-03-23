/**
 * PCR.dev GitHub Webhook — receives pull_request events from GitHub.
 *
 * When a PR is opened or synchronized, this function:
 *   1. Verifies the HMAC-SHA256 signature using GITHUB_WEBHOOK_SECRET
 *   2. Fetches all commits in the PR from the GitHub API
 *   3. Queries cursor_sessions where commit_shas contains any of those SHAs
 *   4. Posts a formatted comment on the PR showing which AI prompts generated the code
 *   5. Updates the matched sessions with github_pr_number, github_pr_url, github_pr_comment_id
 *
 * Environment variables (set in Supabase Vault / function secrets):
 *   GITHUB_WEBHOOK_SECRET  — the secret set when registering the webhook on GitHub
 *   SUPABASE_URL           — auto-provided by Supabase runtime
 *   SUPABASE_SERVICE_ROLE_KEY — auto-provided; used to bypass RLS for cross-user queries
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface PullRequestEvent {
  action: "opened" | "synchronize" | "reopened" | "closed";
  number: number;
  pull_request: {
    html_url: string;
    title: string;
    head: { sha: string; ref: string };
    base: { ref: string };
    user: { login: string };
  };
  repository: {
    full_name: string;  // "owner/repo"
    html_url: string;
  };
  installation?: { id: number };
}

interface GitHubCommit {
  sha: string;
}

interface CursorSession {
  session_id: string;
  name: string | null;
  model_name: string | null;
  unified_mode: string | null;
  context_tokens_used: number | null;
  total_lines_added: number | null;
  total_lines_removed: number | null;
  github_pr_comment_id: number | null;
  project_id: string | null;
  user_id: string | null;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function verifyGitHubSignature(
  secret: string,
  body: string,
  signature: string | null
): Promise<boolean> {
  if (!signature?.startsWith("sha256=")) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  const hex = Array.from(new Uint8Array(mac)).map(b => b.toString(16).padStart(2, "0")).join("");
  return `sha256=${hex}` === signature;
}

async function fetchPRCommits(
  repoFullName: string,
  prNumber: number,
  token: string
): Promise<string[]> {
  const shas: string[] = [];
  let page = 1;
  while (true) {
    const res = await fetch(
      `https://api.github.com/repos/${repoFullName}/pulls/${prNumber}/commits?per_page=100&page=${page}`,
      { headers: { Authorization: `token ${token}`, Accept: "application/vnd.github.v3+json" } }
    );
    if (!res.ok) break;
    const commits: GitHubCommit[] = await res.json();
    if (commits.length === 0) break;
    shas.push(...commits.map(c => c.sha));
    if (commits.length < 100) break;
    page++;
  }
  return shas;
}

function formatPRComment(
  sessions: CursorSession[],
  prTitle: string,
  prUrl: string,
  supabaseUrl: string
): string {
  const appUrl = supabaseUrl.replace("https://", "https://pcr.").replace(".supabase.co", ".dev");
  const lines: string[] = [
    "## PCR.dev — AI Prompts for this PR",
    "",
    `> **${prTitle}**`,
    "",
  ];

  for (const session of sessions) {
    const name      = session.name ?? "Unnamed session";
    const model     = session.model_name ?? "unknown model";
    const mode      = session.unified_mode ?? "agent";
    const ctxK      = session.context_tokens_used ? `${Math.round(session.context_tokens_used / 1000)}k` : null;
    const added     = session.total_lines_added ?? 0;
    const removed   = session.total_lines_removed ?? 0;
    const sessionUrl = `${appUrl}/projects/${session.project_id ?? "_"}/sessions/${session.session_id}`;

    lines.push(`**Session: "${name}"**`);
    lines.push(
      [
        `Model: \`${model}\``,
        `Mode: \`${mode}\``,
        ctxK ? `Context: ${ctxK} tokens` : null,
        (added > 0 || removed > 0) ? `+${added} −${removed} lines` : null,
      ].filter(Boolean).join(" · ")
    );
    lines.push("");
    lines.push(`[View session on PCR.dev →](${sessionUrl})`);
    lines.push("");
  }

  lines.push("---");
  lines.push("*Posted by [PCR.dev](https://pcr.dev) — prompt capture & review*");
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  const webhookSecret = Deno.env.get("GITHUB_WEBHOOK_SECRET");
  const supabaseUrl   = Deno.env.get("SUPABASE_URL")!;
  const serviceKey    = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  if (!webhookSecret) {
    return new Response("GITHUB_WEBHOOK_SECRET not configured", { status: 500 });
  }

  // Only handle POST
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const rawBody = await req.text();
  const signature = req.headers.get("x-hub-signature-256");
  const event     = req.headers.get("x-github-event");

  // Verify HMAC signature
  const valid = await verifyGitHubSignature(webhookSecret, rawBody, signature);
  if (!valid) {
    return new Response("Invalid signature", { status: 401 });
  }

  // Only process pull_request events we care about
  if (event !== "pull_request") {
    return new Response("Ignored", { status: 200 });
  }

  const payload: PullRequestEvent = JSON.parse(rawBody);
  if (!["opened", "synchronize", "reopened"].includes(payload.action)) {
    return new Response("Ignored action", { status: 200 });
  }

  const { pull_request: pr, repository, number: prNumber } = payload;
  const repoFullName = repository.full_name;

  // Service-role client — bypasses RLS so we can query across all users
  const supabase = createClient(supabaseUrl, serviceKey);

  // Find a GitHub token from any user who has connected GitHub and owns a
  // project whose repo_url matches this repository.
  const { data: projectRow } = await supabase
    .from("projects")
    .select("id, created_by")
    .or(`repo_url.ilike.%${repoFullName}%,repo_url.ilike.%${repository.html_url}%`)
    .limit(1)
    .single();

  if (!projectRow) {
    console.log(`No PCR project found for repo ${repoFullName}`);
    return new Response("No matching project", { status: 200 });
  }

  const { data: ghConn } = await supabase
    .from("github_connections")
    .select("access_token")
    .eq("user_id", projectRow.created_by)
    .single();

  if (!ghConn?.access_token) {
    console.log("No GitHub token found for project owner");
    return new Response("No GitHub connection", { status: 200 });
  }

  const token = ghConn.access_token;

  // Fetch all commits in this PR
  const prCommitShas = await fetchPRCommits(repoFullName, prNumber, token);
  if (prCommitShas.length === 0) {
    return new Response("No commits found in PR", { status: 200 });
  }

  // Find sessions that overlap with these commits and haven't been commented on yet
  const { data: sessions } = await supabase
    .from("cursor_sessions")
    .select("session_id, name, model_name, unified_mode, context_tokens_used, total_lines_added, total_lines_removed, github_pr_comment_id, project_id, user_id")
    .eq("project_id", projectRow.id)
    .is("github_pr_comment_id", null)
    .filter("commit_shas", "not.is", null);

  if (!sessions?.length) {
    return new Response("No uncommitted sessions found", { status: 200 });
  }

  // Filter to sessions whose commit_shas intersect with the PR's commits
  const prShaSet = new Set(prCommitShas);
  const { data: allSessions } = await supabase
    .from("cursor_sessions")
    .select("session_id, commit_shas, name, model_name, unified_mode, context_tokens_used, total_lines_added, total_lines_removed, github_pr_comment_id, project_id, user_id")
    .eq("project_id", projectRow.id)
    .is("github_pr_comment_id", null)
    .not("commit_shas", "is", null);

  const matchedSessions: CursorSession[] = (allSessions ?? []).filter((s) => {
    const sessionShas: string[] = s.commit_shas ?? [];
    return sessionShas.some((sha: string) => prShaSet.has(sha));
  });

  if (matchedSessions.length === 0) {
    return new Response("No sessions match this PR's commits", { status: 200 });
  }

  // Post comment
  const commentBody = formatPRComment(
    matchedSessions,
    pr.title,
    pr.html_url,
    supabaseUrl
  );

  const commentRes = await fetch(
    `https://api.github.com/repos/${repoFullName}/issues/${prNumber}/comments`,
    {
      method: "POST",
      headers: {
        Authorization: `token ${token}`,
        Accept: "application/vnd.github.v3+json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ body: commentBody }),
    }
  );

  if (!commentRes.ok) {
    const err = await commentRes.text();
    console.error("Failed to post comment:", err);
    return new Response("Failed to post comment", { status: 500 });
  }

  const comment = await commentRes.json();
  const commentId: number = comment.id;
  const prUrl = pr.html_url;

  // Update matched sessions with PR info
  for (const session of matchedSessions) {
    await supabase.rpc("set_session_pr", {
      p_session_id: session.session_id,
      p_pr_number:  prNumber,
      p_pr_url:     prUrl,
      p_comment_id: commentId,
    });
  }

  console.log(`Posted PR comment #${commentId} for ${matchedSessions.length} sessions`);
  return new Response(JSON.stringify({ ok: true, sessions: matchedSessions.length, commentId }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
