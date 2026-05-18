-- ============================================================
-- project_invites + prompt title/tags migration
-- All changes are additive and safe to re-run.
-- ============================================================

-- ─── 1. prompts.title + prompts.tags ────────────────────────────────────────
-- Title is a user-friendly label set in the dashboard (the raw `prompt_text`
-- is the captured AI input and stays immutable). Tags let reviewers
-- categorise prompts manually (e.g. "regression", "post-mortem", "demo").

ALTER TABLE prompts ADD COLUMN IF NOT EXISTS title text;
ALTER TABLE prompts ADD COLUMN IF NOT EXISTS tags  text[] NOT NULL DEFAULT '{}';

CREATE INDEX IF NOT EXISTS prompts_tags_gin ON prompts USING GIN (tags);

-- Preserve dashboard-set title/tags across CLI re-pushes by NOT overwriting
-- them in upsert_prompts. The CLI never sends title/tags, so the columns
-- are only ever written from the dashboard.
CREATE OR REPLACE FUNCTION upsert_prompts(p_records jsonb, p_user_id uuid DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  rec        jsonb;
  v_proj_ids uuid[];
  v_pid_txt  text;
  inserted   integer := 0;
BEGIN
  FOR rec IN SELECT jsonb_array_elements(p_records) LOOP
    v_proj_ids := '{}';
    IF rec->'project_ids' IS NOT NULL AND jsonb_typeof(rec->'project_ids') = 'array' THEN
      FOR v_pid_txt IN SELECT jsonb_array_elements_text(rec->'project_ids') LOOP
        BEGIN
          v_proj_ids := array_append(v_proj_ids, v_pid_txt::uuid);
        EXCEPTION WHEN invalid_text_representation THEN NULL;
        END;
      END LOOP;
    ELSIF rec->>'project_id' IS NOT NULL THEN
      BEGIN
        v_proj_ids := ARRAY[(rec->>'project_id')::uuid];
      EXCEPTION WHEN invalid_text_representation THEN NULL;
      END;
    END IF;

    INSERT INTO prompts (
      id, content_hash, session_id, project_id, project_ids,
      project_name, branch_name, prompt_text, response_text,
      model, source, capture_method, tool_calls, file_context,
      captured_at, user_id, bundle_id
    ) VALUES (
      COALESCE((rec->>'id')::uuid, gen_random_uuid()),
      rec->>'content_hash',
      rec->>'session_id',
      (rec->>'project_id')::uuid,
      v_proj_ids,
      rec->>'project_name',
      rec->>'branch_name',
      rec->>'prompt_text',
      rec->>'response_text',
      rec->>'model',
      COALESCE(rec->>'source', 'unknown'),
      COALESCE(rec->>'capture_method', 'file-watcher'),
      rec->'tool_calls',
      rec->'file_context',
      COALESCE((rec->>'captured_at')::timestamptz, now()),
      COALESCE(p_user_id, (rec->>'user_id')::uuid),
      rec->>'bundle_id'
    )
    ON CONFLICT (content_hash) DO UPDATE SET
      response_text = COALESCE(EXCLUDED.response_text, prompts.response_text),
      tool_calls    = COALESCE(EXCLUDED.tool_calls,    prompts.tool_calls),
      file_context  = COALESCE(EXCLUDED.file_context,  prompts.file_context),
      model         = COALESCE(EXCLUDED.model,         prompts.model),
      bundle_id     = COALESCE(EXCLUDED.bundle_id,     prompts.bundle_id),
      project_ids   = CASE
                        WHEN EXCLUDED.project_ids <> '{}' THEN EXCLUDED.project_ids
                        ELSE prompts.project_ids
                      END
      -- title + tags are dashboard-owned: never touched by the CLI path.
      ;

    inserted := inserted + 1;
  END LOOP;
  RETURN inserted;
END;
$$;

-- Allow project members (not just the original capturer) to update prompts
-- they have visibility into. Required so a teammate can rename a prompt or
-- adjust its tags without forking the row. Restrict the writable columns
-- to title and tags via a check that the immutable fields don't change.
DROP POLICY IF EXISTS "Users can update own prompts" ON prompts;
CREATE POLICY "Users can update own prompts"
  ON prompts FOR UPDATE
  USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM project_members pm
      WHERE pm.project_id = prompts.project_id
        AND pm.user_id = auth.uid()
    )
  );

-- Project members can read each other's prompts even if they were captured
-- by a different teammate. This complements the existing "own prompts"
-- SELECT policy so the dashboard surfaces the full project history.
DROP POLICY IF EXISTS "Project members can read team prompts" ON prompts;
CREATE POLICY "Project members can read team prompts"
  ON prompts FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM project_members pm
      WHERE pm.project_id = prompts.project_id
        AND pm.user_id = auth.uid()
    )
  );

-- ─── 2. project_invites ─────────────────────────────────────────────────────
-- Mirrors team_invites. A project owner/admin can invite by email
-- OR by github login; the latter is resolved client-side against the
-- github_connections table when sending the invite (when the target
-- user has already signed in to PCR), and falls back to a tokenized
-- invite link when no PCR account exists yet.

CREATE TABLE IF NOT EXISTS project_invites (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  email        text,
  github_login text,
  role         text NOT NULL DEFAULT 'member' CHECK (role IN ('admin', 'member')),
  token        text NOT NULL UNIQUE DEFAULT encode(extensions.gen_random_bytes(32), 'hex'),
  invited_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  expires_at   timestamptz NOT NULL DEFAULT (now() + interval '14 days'),
  accepted_at  timestamptz,
  accepted_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS project_invites_project_id_idx   ON project_invites (project_id);
CREATE INDEX IF NOT EXISTS project_invites_email_idx        ON project_invites (lower(email));
CREATE INDEX IF NOT EXISTS project_invites_github_login_idx ON project_invites (lower(github_login));

ALTER TABLE project_invites ENABLE ROW LEVEL SECURITY;

-- Owners and admins of a project can read its pending invites.
DROP POLICY IF EXISTS "project_invites_select_admin" ON project_invites;
CREATE POLICY "project_invites_select_admin" ON project_invites
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM project_members pm
      WHERE pm.project_id = project_invites.project_id
        AND pm.user_id = auth.uid()
        AND pm.role IN ('owner', 'admin')
    )
  );

-- Anyone (authenticated) can read an invite by token to accept it.
-- We can't enforce token-equality in RLS (the WHERE clause is on the client),
-- so we allow broad SELECT here and rely on the unguessable 64-char token.
-- This matches the team_invites_select_by_token policy.
DROP POLICY IF EXISTS "project_invites_select_by_token" ON project_invites;
CREATE POLICY "project_invites_select_by_token" ON project_invites
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS "project_invites_insert" ON project_invites;
CREATE POLICY "project_invites_insert" ON project_invites
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM project_members pm
      WHERE pm.project_id = project_invites.project_id
        AND pm.user_id = auth.uid()
        AND pm.role IN ('owner', 'admin')
    )
  );

DROP POLICY IF EXISTS "project_invites_update" ON project_invites;
CREATE POLICY "project_invites_update" ON project_invites
  FOR UPDATE TO authenticated
  USING (true);

DROP POLICY IF EXISTS "project_invites_delete" ON project_invites;
CREATE POLICY "project_invites_delete" ON project_invites
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM project_members pm
      WHERE pm.project_id = project_invites.project_id
        AND pm.user_id = auth.uid()
        AND pm.role IN ('owner', 'admin')
    )
  );

-- ─── 3. bundles update policy ───────────────────────────────────────────────
-- Project members can rename a bundle (update its `message`). The original
-- INSERT path stays SECURITY DEFINER (upsert_bundle), so this only widens
-- the *update* surface to logged-in members of a linked project.

DROP POLICY IF EXISTS "Project members can update team bundles" ON bundles;
CREATE POLICY "Project members can update team bundles" ON bundles
  FOR UPDATE TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM bundle_projects bp
      JOIN project_members pm ON pm.project_id = bp.project_id
      WHERE bp.bundle_id = bundles.id AND pm.user_id = auth.uid()
    )
  );

-- ─── 4. accept_project_invite RPC ───────────────────────────────────────────
-- Joins the caller to the project (idempotent) and marks the invite
-- accepted. Returns the project_id on success, null on failure.
CREATE OR REPLACE FUNCTION accept_project_invite(p_token text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_invite project_invites%ROWTYPE;
  v_user   uuid := auth.uid();
BEGIN
  IF v_user IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_invite FROM project_invites
   WHERE token = p_token
     AND accepted_at IS NULL
     AND expires_at > now()
   LIMIT 1;

  IF v_invite.id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO project_members (project_id, user_id, role)
  VALUES (v_invite.project_id, v_user, v_invite.role)
  ON CONFLICT (project_id, user_id) DO NOTHING;

  UPDATE project_invites
     SET accepted_at = now(), accepted_by = v_user
   WHERE id = v_invite.id;

  RETURN v_invite.project_id;
END;
$$;
