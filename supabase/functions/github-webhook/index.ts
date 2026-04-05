/**
 * PCR.dev GitHub Webhook — receives pull_request events from GitHub.
 *
 * When a PR is opened or synchronized, this function:
 *   1. Verifies the HMAC-SHA256 signature using GITHUB_WEBHOOK_SECRET
 *   2. Fetches all commits in the PR from the GitHub API
 *   3. Queries cursor_sessions AND bundles where session_shas contains any of those SHAs
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
  commit_shas: string[] | null;
  github_pr_comment_id: number | null;
  project_id: string | null;
  user_id: string | null;
}

interface Bundle {
  bundle_id: string;
  message: string;
  project_name: string | null;
  exchange_count: number | null;
  session_shas: string[] | null;
  github_pr_comment_id: number | null;
  bundle_projects: { project_id: string }[];
}

interface MatchedSession {
  session_id: string;
  source: "cursor" | "claude-code";
  name: string;
  model: string;
  mode: string | null;
  contextTokensK: string | null;
  linesAdded: number;
  linesRemoved: number;
  project_id: string | null;
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

function normalizeCursorSession(s: CursorSession): MatchedSession {
  return {
    session_id: s.session_id,
    source: "cursor",
    name: s.name ?? "Unnamed session",
    model: s.model_name ?? "unknown model",
    mode: s.unified_mode ?? "agent",
    contextTokensK: s.context_tokens_used ? `${Math.round(s.context_tokens_used / 1000)}k` : null,
    linesAdded: s.total_lines_added ?? 0,
    linesRemoved: s.total_lines_removed ?? 0,
    project_id: s.project_id,
  };
}

function normalizeBundle(b: Bundle): MatchedSession {
  return {
    session_id: b.bundle_id,
    source: "claude-code",
    name: b.message,
    model: "claude-code",
    mode: "claude-code",
    contextTokensK: b.exchange_count ? `${b.exchange_count} prompts` : null,
    linesAdded: 0,
    linesRemoved: 0,
    project_id: b.bundle_projects?.[0]?.project_id ?? null,
  };
}

function formatPRComment(
  sessions: MatchedSession[],
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
    const sessionUrl = session.source === "cursor"
      ? `${appUrl}/projects/${session.project_id ?? "_"}/sessions/${session.session_id}`
      : `${appUrl}/review/${session.session_id}`;

    lines.push(`**Session: "${session.name}"**`);
    lines.push(
      [
        `Model: \`${session.model}\``,
        `Source: \`${session.source}\``,
        session.contextTokensK ? `Tokens: ${session.contextTokensK}` : null,
        (session.linesAdded > 0 || session.linesRemoved > 0)
          ? `+${session.linesAdded} −${session.linesRemoved} lines` : null,
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

  // Query cursor_sessions and bundles in parallel for matching commits
  const prShaSet = new Set(prCommitShas);

  const [{ data: rawCursorSessions }, { data: rawBundles }] = await Promise.all([
    supabase
      .from("cursor_sessions")
      .select("session_id, commit_shas, name, model_name, unified_mode, context_tokens_used, total_lines_added, total_lines_removed, github_pr_comment_id, project_id, user_id")
      .eq("project_id", projectRow.id)
      .is("github_pr_comment_id", null)
      .not("commit_shas", "is", null),
    supabase
      .from("bundles")
      .select("bundle_id, message, project_name, exchange_count, session_shas, github_pr_comment_id, bundle_projects!inner(project_id)")
      .eq("bundle_projects.project_id", projectRow.id)
      .is("github_pr_comment_id", null)
      .not("session_shas", "is", null),
  ]);

  const matchedCursor: MatchedSession[] = (rawCursorSessions ?? [])
    .filter((s) => (s.commit_shas as string[] ?? []).some((sha: string) => prShaSet.has(sha)))
    .map(normalizeCursorSession);

  const matchedClaude: MatchedSession[] = (rawBundles ?? [])
    .filter((b) => (b.session_shas as string[] ?? []).some((sha: string) => prShaSet.has(sha)))
    .map(normalizeBundle);

  const matchedSessions = [...matchedCursor, ...matchedClaude];

  if (matchedSessions.length === 0) {
    return new Response("No sessions match this PR's commits", { status: 200 });
  }

  // Post comment
  const commentBody = formatPRComment(matchedSessions, pr.title, pr.html_url, supabaseUrl);

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

  // Mark matched sessions so they aren't included in future PR sync events
  await Promise.all([
    ...matchedCursor.map((s) =>
      supabase.rpc("set_session_pr", {
        p_session_id: s.session_id,
        p_pr_number:  prNumber,
        p_pr_url:     prUrl,
        p_comment_id: commentId,
      })
    ),
    ...(matchedClaude.length > 0
      ? [supabase
          .from("bundles")
          .update({ github_pr_comment_id: commentId, github_pr_number: prNumber, github_pr_url: prUrl })
          .in("bundle_id", matchedClaude.map((s) => s.session_id))]
      : []),
  ]);

  console.log(`Posted PR comment #${commentId} for ${matchedSessions.length} sessions (cursor: ${matchedCursor.length}, claude: ${matchedClaude.length})`);
  return new Response(JSON.stringify({ ok: true, sessions: matchedSessions.length, commentId }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
