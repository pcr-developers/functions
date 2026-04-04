-- Drop pre-existing trigger that used pgcrypto for content hashing.
-- content_hash is now computed by the CLI before push.
DROP TRIGGER IF EXISTS auto_content_hash ON prompts;

-- prompts: one row per prompt, the main data table.
-- bundle_id is a soft reference (not FK) — can be a bundle ID, session ID, etc.

CREATE TABLE IF NOT EXISTS prompts (
  id              uuid PRIMARY KEY,
  bundle_id       text,
  user_id         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  project_id      uuid REFERENCES projects(id) ON DELETE SET NULL,
  session_id      text,
  prompt_text     text NOT NULL,
  response_text   text,
  tool_calls      jsonb,
  model           text,
  source          text,
  branch_name     text,
  captured_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- Add columns that may be missing if the table already existed
ALTER TABLE prompts ADD COLUMN IF NOT EXISTS bundle_id     text;
ALTER TABLE prompts ADD COLUMN IF NOT EXISTS session_id    text;
ALTER TABLE prompts ADD COLUMN IF NOT EXISTS response_text text;
ALTER TABLE prompts ADD COLUMN IF NOT EXISTS tool_calls    jsonb;
ALTER TABLE prompts ADD COLUMN IF NOT EXISTS model         text;
ALTER TABLE prompts ADD COLUMN IF NOT EXISTS source        text;
ALTER TABLE prompts ADD COLUMN IF NOT EXISTS branch_name   text;
ALTER TABLE prompts ADD COLUMN IF NOT EXISTS captured_at   timestamptz;

CREATE INDEX IF NOT EXISTS prompts_bundle_id_idx    ON prompts (bundle_id);
CREATE INDEX IF NOT EXISTS prompts_user_id_idx      ON prompts (user_id);
CREATE INDEX IF NOT EXISTS prompts_project_id_idx   ON prompts (project_id);
CREATE INDEX IF NOT EXISTS prompts_session_id_idx   ON prompts (session_id);

ALTER TABLE prompts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own prompts" ON prompts;
CREATE POLICY "Users can read own prompts"
  ON prompts FOR SELECT
  USING (user_id = auth.uid());

-- git_diffs: large diffs stored separately, joined only when needed.

CREATE TABLE IF NOT EXISTS git_diffs (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  prompt_id  uuid NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
  diff       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS git_diffs_prompt_id_idx ON git_diffs (prompt_id);

ALTER TABLE git_diffs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own git diffs" ON git_diffs;
CREATE POLICY "Users can read own git diffs"
  ON git_diffs FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM prompts p
      WHERE p.id = git_diffs.prompt_id
        AND p.user_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- upsert_prompts RPC — batch upsert, returns count inserted/updated
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS upsert_prompts(jsonb);
DROP FUNCTION IF EXISTS upsert_prompts(jsonb, uuid);

CREATE OR REPLACE FUNCTION upsert_prompts(p_records jsonb, p_user_id uuid DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rec    jsonb;
  n      integer := 0;
BEGIN
  FOR rec IN SELECT * FROM jsonb_array_elements(p_records)
  LOOP
    INSERT INTO prompts (
      id, content_hash, bundle_id, user_id, project_id, session_id,
      prompt_text, response_text, tool_calls,
      model, source, branch_name, captured_at
    ) VALUES (
      (rec->>'id')::uuid,
      rec->>'content_hash',
      rec->>'bundle_id',
      p_user_id,
      (rec->>'project_id')::uuid,
      rec->>'session_id',
      rec->>'prompt_text',
      rec->>'response_text',
      rec->'tool_calls',
      rec->>'model',
      rec->>'source',
      rec->>'branch_name',
      (rec->>'captured_at')::timestamptz
    )
    ON CONFLICT (id) DO UPDATE SET
      bundle_id     = COALESCE(EXCLUDED.bundle_id,     prompts.bundle_id),
      response_text = COALESCE(EXCLUDED.response_text, prompts.response_text),
      tool_calls    = COALESCE(EXCLUDED.tool_calls,    prompts.tool_calls),
      model         = COALESCE(EXCLUDED.model,         prompts.model);
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$;

-- ---------------------------------------------------------------------------
-- upsert_git_diffs RPC — batch upsert diffs by prompt_id
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION upsert_git_diffs(p_diffs jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rec jsonb;
BEGIN
  FOR rec IN SELECT * FROM jsonb_array_elements(p_diffs)
  LOOP
    INSERT INTO git_diffs (prompt_id, diff)
    VALUES ((rec->>'prompt_id')::uuid, rec->>'diff')
    ON CONFLICT (prompt_id) DO NOTHING;
  END LOOP;
END;
$$;
