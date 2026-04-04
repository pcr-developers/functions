-- claude_bundles: replaces claude_sessions.
-- Written at pcr push time (not capture time), keyed on bundle_id.
-- session_shas carries the git commits associated with the bundle,
-- used by the GitHub webhook to match bundles to PRs.
-- items stores the full prompt/response/diff data as JSONB (one row per bundle).

DROP TABLE IF EXISTS claude_sessions CASCADE;

CREATE TABLE IF NOT EXISTS claude_bundles (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bundle_id            text NOT NULL UNIQUE,
  message              text NOT NULL,
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

ALTER TABLE claude_bundles DROP COLUMN IF EXISTS items;

CREATE INDEX IF NOT EXISTS claude_bundles_project_id_idx   ON claude_bundles (project_id);
CREATE INDEX IF NOT EXISTS claude_bundles_user_id_idx      ON claude_bundles (user_id);
CREATE INDEX IF NOT EXISTS claude_bundles_session_shas_idx ON claude_bundles USING GIN (session_shas);

ALTER TABLE claude_bundles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own claude bundles" ON claude_bundles;
CREATE POLICY "Users can read own claude bundles"
  ON claude_bundles FOR SELECT
  USING (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- upsert_claude_bundle RPC
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS upsert_claude_session(jsonb);
DROP FUNCTION IF EXISTS upsert_claude_bundle(jsonb, uuid);

CREATE OR REPLACE FUNCTION upsert_claude_bundle(p_bundle jsonb, p_user_id uuid DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO claude_bundles (
    bundle_id,
    message,
    project_id,
    user_id,
    project_name,
    branch_name,
    session_shas,
    head_sha,
    exchange_count,
    items,
    committed_at,
    pushed_at
  ) VALUES (
    p_bundle->>'bundle_id',
    p_bundle->>'message',
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
    project_id     = COALESCE(EXCLUDED.project_id, claude_bundles.project_id),
    user_id        = COALESCE(EXCLUDED.user_id, claude_bundles.user_id),
    session_shas   = COALESCE(EXCLUDED.session_shas, claude_bundles.session_shas),
    head_sha       = COALESCE(EXCLUDED.head_sha, claude_bundles.head_sha),
    exchange_count = GREATEST(EXCLUDED.exchange_count, claude_bundles.exchange_count),
    items          = COALESCE(EXCLUDED.items, claude_bundles.items),
    pushed_at      = now(),
    updated_at     = now()
  RETURNING id INTO v_id;

  RETURN v_id::text;
END;
$$;
