-- claude_sessions: session-level stats for Claude Code captures
-- Mirrors cursor_sessions but uses Claude-native fields (no SQLite enrichment).
-- Upserted once per session file tick; keyed on session_id.

CREATE TABLE IF NOT EXISTS claude_sessions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id          text NOT NULL UNIQUE,
  project_id          uuid REFERENCES projects(id) ON DELETE SET NULL,
  user_id             uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  project_name        text,
  branch              text,
  model_name          text,
  total_input_tokens  integer NOT NULL DEFAULT 0,
  total_output_tokens integer NOT NULL DEFAULT 0,
  exchange_count      integer NOT NULL DEFAULT 0,
  session_created_at  timestamptz,
  session_updated_at  timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS claude_sessions_project_id_idx ON claude_sessions (project_id);
CREATE INDEX IF NOT EXISTS claude_sessions_user_id_idx    ON claude_sessions (user_id);

-- RLS: users can read their own sessions; service role can write.
ALTER TABLE claude_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own claude sessions"
  ON claude_sessions FOR SELECT
  USING (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- upsert_claude_session RPC
-- SECURITY DEFINER so the anon key can write without bypassing RLS.
-- ON CONFLICT merges: always refresh token counts & exchange_count;
-- coalesce project_id / user_id once set.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION upsert_claude_session(p_session jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO claude_sessions (
    session_id,
    project_id,
    user_id,
    project_name,
    branch,
    model_name,
    total_input_tokens,
    total_output_tokens,
    exchange_count,
    session_created_at,
    session_updated_at
  ) VALUES (
    p_session->>'session_id',
    (p_session->>'project_id')::uuid,
    (p_session->>'user_id')::uuid,
    p_session->>'project_name',
    p_session->>'branch',
    p_session->>'model_name',
    COALESCE((p_session->>'total_input_tokens')::integer, 0),
    COALESCE((p_session->>'total_output_tokens')::integer, 0),
    COALESCE((p_session->>'exchange_count')::integer, 0),
    (p_session->>'session_created_at')::timestamptz,
    (p_session->>'session_updated_at')::timestamptz
  )
  ON CONFLICT (session_id) DO UPDATE SET
    project_id          = COALESCE(EXCLUDED.project_id, claude_sessions.project_id),
    user_id             = COALESCE(EXCLUDED.user_id, claude_sessions.user_id),
    project_name        = COALESCE(EXCLUDED.project_name, claude_sessions.project_name),
    branch              = COALESCE(EXCLUDED.branch, claude_sessions.branch),
    model_name          = COALESCE(EXCLUDED.model_name, claude_sessions.model_name),
    total_input_tokens  = GREATEST(EXCLUDED.total_input_tokens, claude_sessions.total_input_tokens),
    total_output_tokens = GREATEST(EXCLUDED.total_output_tokens, claude_sessions.total_output_tokens),
    exchange_count      = GREATEST(EXCLUDED.exchange_count, claude_sessions.exchange_count),
    session_created_at  = COALESCE(claude_sessions.session_created_at, EXCLUDED.session_created_at),
    session_updated_at  = CASE
                            WHEN EXCLUDED.session_updated_at IS NOT NULL
                             AND (claude_sessions.session_updated_at IS NULL
                                  OR EXCLUDED.session_updated_at > claude_sessions.session_updated_at)
                            THEN EXCLUDED.session_updated_at
                            ELSE claude_sessions.session_updated_at
                          END,
    updated_at          = now();
END;
$$;
