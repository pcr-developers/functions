# pcr-developers / functions

Supabase project that backs the **database** and **edge functions** for
[pcr.dev](https://pcr.dev). The web app and CLI live in sibling repos and talk
to this project via the standard Supabase client.

## Layout

```
supabase/
  config.toml?       (not currently committed — see "Config" below)
  migrations/        SQL migrations, applied via `supabase db push`
  functions/         Deno edge functions
    github-webhook/  Receives GitHub pull_request events; see its README
```

## Linked project

`supabase/.temp/linked-project.json` (gitignored) records the linked Supabase
project ref. To re-link a fresh checkout:

```bash
supabase link --project-ref <ref>
```

## Deploying edge functions

Each function is deployed individually:

```bash
supabase functions deploy github-webhook
```

Function secrets (per-environment) are set with:

```bash
supabase secrets set GITHUB_WEBHOOK_SECRET=...
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are auto-injected by the
Supabase runtime — never set them manually.

## Local development

Requires Docker. Spin up the full stack, then serve a single function:

```bash
supabase start
supabase functions serve github-webhook --no-verify-jwt
```

## Migrations

See `supabase/migrations/`. Migrations are applied with `supabase db push`.
Do not hand-edit applied migrations; create a new one instead.

## CI / deploy automation

Currently none. Both migrations and function deploys are run manually. See
[`supabase/functions/github-webhook/README.md`](supabase/functions/github-webhook/README.md)
for the deploy checklist for that function.
