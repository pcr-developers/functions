-- Unified bundles table (superset of claude_bundles + source column).
-- All sources (cursor, claude-code, future) write here.
-- claude_bundles is kept as a deprecated backup.

-- 1. Create bundles table
CREATE TABLE IF NOT EXISTS bundles (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bundle_id            text NOT NULL UNIQUE,
  remote_id            text,
  message              text NOT NULL,
  source               text NOT NULL DEFAULT 'unknown',
  project_id           uuid REFERENCES projects(id) ON DELETE SET NULL,
  user_id              uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  project_name         text,
  branch_name          text,
  session_shas         text[],
  head_sha             text,
  exchange_count       integer NOT NULL DEFAULT 0,
  items                jsonb,
  committed_at         timestamptz,
  pushed_at            timestamptz NOT NULL DEFAULT now(),
  github_pr_comment_id bigint,
  github_pr_number     integer,
  github_pr_url        text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bundles_project_id_idx   ON bundles (project_id);
CREATE INDEX IF NOT EXISTS bundles_user_id_idx      ON bundles (user_id);
CREATE INDEX IF NOT EXISTS bundles_source_idx       ON bundles (source);
CREATE INDEX IF NOT EXISTS bundles_session_shas_idx ON bundles USING GIN (session_shas);

-- 2. Migrate existing claude_bundles rows into bundles with source='claude-code'
INSERT INTO bundles (
  id, bundle_id, remote_id, message, source,
  project_id, user_id, project_name, branch_name,
  session_shas, head_sha, exchange_count, items,
  committed_at, pushed_at, github_pr_comment_id,
  github_pr_number, github_pr_url, created_at, updated_at
)
SELECT
  id, bundle_id, remote_id, message, 'claude-code',
  project_id, user_id, project_name, branch_name,
  session_shas, head_sha, exchange_count, items,
  committed_at, pushed_at, github_pr_comment_id,
  github_pr_number, github_pr_url, created_at, updated_at
FROM claude_bundles
ON CONFLICT (bundle_id) DO NOTHING;

-- 3. RLS on bundles
ALTER TABLE bundles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own bundles" ON bundles;
CREATE POLICY "Users can read own bundles" ON bundles
  FOR SELECT USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Team members can read team bundles" ON bundles;
CREATE POLICY "Team members can read team bundles" ON bundles
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM project_members pm
      WHERE pm.project_id = bundles.project_id AND pm.user_id = auth.uid()
    )
  );

-- 4. upsert_bundle RPC — called by pcr push for all sources
DROP FUNCTION IF EXISTS upsert_bundle(jsonb, uuid);
CREATE OR REPLACE FUNCTION upsert_bundle(p_bundle jsonb, p_user_id uuid DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO bundles (
    bundle_id, message, source, project_id, user_id,
    project_name, branch_name, session_shas, head_sha,
    exchange_count, items, committed_at, pushed_at
  ) VALUES (
    p_bundle->>'bundle_id',
    p_bundle->>'message',
    COALESCE(p_bundle->>'source', 'unknown'),
    (p_bundle->>'project_id')::uuid,
    p_user_id,
    p_bundle->>'project_name',
    p_bundle->>'branch_name',
    ARRAY(SELECT jsonb_array_elements_text(p_bundle->'session_shas')),
    p_bundle->>'head_sha',
    COALESCE((p_bundle->>'exchange_count')::integer, 0),
    p_bundle->'items',
    (p_bundle->>'committed_at')::timestamptz,
    now()
  )
  ON CONFLICT (bundle_id) DO UPDATE SET
    message        = EXCLUDED.message,
    source         = COALESCE(EXCLUDED.source, bundles.source),
    project_id     = COALESCE(EXCLUDED.project_id, bundles.project_id),
    user_id        = COALESCE(EXCLUDED.user_id, bundles.user_id),
    session_shas   = COALESCE(EXCLUDED.session_shas, bundles.session_shas),
    head_sha       = COALESCE(EXCLUDED.head_sha, bundles.head_sha),
    exchange_count = GREATEST(EXCLUDED.exchange_count, bundles.exchange_count),
    items          = COALESCE(EXCLUDED.items, bundles.items),
    pushed_at      = now(),
    updated_at     = now()
  RETURNING id INTO v_id;
  RETURN v_id::text;
END;
$$;

-- 5. Ensure project_members has a unique constraint for ON CONFLICT to work
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'project_members_project_user_unique'
  ) THEN
    ALTER TABLE project_members
      ADD CONSTRAINT project_members_project_user_unique UNIQUE (project_id, user_id);
  END IF;
END $$;

-- 6. Fix register_project: match by repo_url (provider-agnostic) + auto-add caller to project_members.
-- p_user_id is passed explicitly because CLI tokens are not Supabase JWTs,
-- so auth.uid() would be NULL when called from the CLI.
CREATE OR REPLACE FUNCTION register_project(p_name text, p_git_remote text, p_local_path text, p_user_id uuid DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id    uuid;
  v_actor uuid;
BEGIN
  -- Resolve user: prefer explicit p_user_id, fall back to auth.uid() for dashboard calls
  v_actor := COALESCE(p_user_id, auth.uid());

  -- Match existing project by repo URL (works for GitHub, GitLab, Bitbucket, etc.)
  SELECT id INTO v_id FROM projects WHERE repo_url = p_git_remote LIMIT 1;

  IF v_id IS NULL THEN
    INSERT INTO projects (name, slug, repo_url, created_by)
    VALUES (p_name, p_name, p_git_remote, v_actor)
    RETURNING id INTO v_id;
  END IF;

  -- Auto-add calling user to project_members (idempotent)
  IF v_actor IS NOT NULL THEN
    INSERT INTO project_members (project_id, user_id, role)
    VALUES (v_id, v_actor, 'member')
    ON CONFLICT (project_id, user_id) DO NOTHING;
  END IF;

  RETURN v_id::text;
END;
$$;
