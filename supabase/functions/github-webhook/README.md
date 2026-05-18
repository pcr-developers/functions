# github-webhook

Edge Function that receives GitHub `pull_request` events and posts a comment
on the PR listing the AI prompts / sessions that produced the code.

## When it's invoked

GitHub delivers a `pull_request` event whenever a PR is **opened**,
**synchronized** (new commits pushed), or **reopened**. Only those three
actions are processed; everything else is ignored with a 200 response.

## Flow

1. Verify the `x-hub-signature-256` HMAC against `GITHUB_WEBHOOK_SECRET`.
2. Reject non-`pull_request` events (200, ignored).
3. JSON-parse + shape-validate the payload (400 on malformed input).
4. Look up a PCR project whose `repo_url` references this repository.
5. Look up the `github_connections` token for the project owner.
6. Fetch all commit SHAs in the PR from the GitHub API.
7. Query `cursor_sessions` and `bundles` for rows that share any SHA with
   the PR **and** haven't already been posted (`github_pr_comment_id IS NULL`).
8. Post a markdown comment on the PR with one entry per matched session.
9. Mark each matched session with the PR / comment id so subsequent
   `synchronize` events don't duplicate the comment.

## Environment variables

| Variable                     | Source                  | Purpose                                                   |
| ---------------------------- | ----------------------- | --------------------------------------------------------- |
| `GITHUB_WEBHOOK_SECRET`      | `supabase secrets set`  | HMAC shared secret configured on the GitHub webhook.      |
| `SUPABASE_URL`               | Supabase runtime (auto) | Used to build session URLs and the Supabase client.       |
| `SUPABASE_SERVICE_ROLE_KEY`  | Supabase runtime (auto) | Bypasses RLS so we can match sessions across all users.   |

## GitHub webhook configuration

On the GitHub repo (or org) → **Settings → Webhooks → Add webhook**:

- **Payload URL**: `https://<project-ref>.supabase.co/functions/v1/github-webhook`
- **Content type**: `application/json`
- **Secret**: matches `GITHUB_WEBHOOK_SECRET`
- **Events**: just **Pull requests**

## Database surface used

- `projects (id, created_by, repo_url)` — owner lookup
- `github_connections (user_id, access_token)` — GitHub OAuth token
- `cursor_sessions (..., commit_shas[], github_pr_comment_id, ...)`
- `bundles (..., session_shas[], github_pr_comment_id, ...)`
- `bundle_projects (bundle_id, project_id)` — many-to-many join
- `set_session_pr(p_session_id, p_pr_number, p_pr_url, p_comment_id)` RPC

## Status codes

| Status | Meaning                                                                 |
| ------ | ----------------------------------------------------------------------- |
| 200    | Successfully processed, or intentionally ignored (wrong event/action).  |
| 400    | Malformed JSON or payload shape.                                        |
| 401    | Invalid `x-hub-signature-256`.                                          |
| 405    | Non-`POST` method.                                                      |
| 500    | Server misconfigured (missing env) or unexpected internal error.        |
| 502    | Upstream GitHub API call failed (e.g. comment creation).                |

## Deploy

```bash
supabase functions deploy github-webhook
```

Set the secret once per environment:

```bash
supabase secrets set GITHUB_WEBHOOK_SECRET=<value>
```

## Local development

```bash
supabase start                                           # full stack (Docker)
supabase functions serve github-webhook --no-verify-jwt  # serve this function
```

Simulate a delivery by replaying a saved payload (signature must match
your local `GITHUB_WEBHOOK_SECRET`):

```bash
curl -X POST http://127.0.0.1:54321/functions/v1/github-webhook \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: pull_request" \
  -H "X-Hub-Signature-256: sha256=<computed-hmac>" \
  --data @sample-pull-request.json
```

## Known limitations (tracked separately)

- `repo_url` matching uses a loose `ilike %…%` substring filter. Tighter
  matching would require a schema change (a dedicated `repo_full_name`
  column with `eq` lookup) — see the audit report.
- `set_session_pr` is called per cursor session (small N in practice, but
  could be batched via a new RPC that accepts an array of session ids).
- No CI for deploys; both migrations and function deploys are manual.
