-- bundle_projects: junction table linking bundles to every repo they touched.
-- forced poll test - functions only
-- A single bundle can span multiple repos (e.g. a prompt that edited both
-- cli/ and pcr-dev/ in the same Cursor session).

-- 1. Junction table
CREATE TABLE IF NOT EXISTS bundle_projects (
  bundle_id  uuid NOT NULL REFERENCES bundles(id)   ON DELETE CASCADE,
  project_id uuid NOT NULL REFERENCES projects(id)  ON DELETE CASCADE,
  PRIMARY KEY (bundle_id, project_id)
);

CREATE INDEX IF NOT EXISTS bundle_projects_project_id_idx ON bundle_projects (project_id);

-- 2. RLS
ALTER TABLE bundle_projects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own bundle_projects" ON bundle_projects;
CREATE POLICY "Users can read own bundle_projects" ON bundle_projects
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM bundles b
      WHERE b.id = bundle_id AND b.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Team members can read bundle_projects" ON bundle_projects;
CREATE POLICY "Team members can read bundle_projects" ON bundle_projects
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM bundles b
      JOIN project_members pm ON pm.project_id = b.project_id
      WHERE b.id = bundle_id AND pm.user_id = auth.uid()
    )
  );

-- 3. Backfill existing bundles: each bundle already belongs to its primary project.
INSERT INTO bundle_projects (bundle_id, project_id)
SELECT id, project_id FROM bundles WHERE project_id IS NOT NULL
ON CONFLICT DO NOTHING;

-- 4. Update upsert_bundle to also write bundle_projects junction rows.
--
-- touched_project_ids is embedded in p_bundle as a JSON string array
-- (same approach as session_shas) to avoid PostgREST uuid[] cast issues.
-- The Go side sets p_bundle.touched_project_ids = ["uuid1", "uuid2", ...].
DROP FUNCTION IF EXISTS upsert_bundle(jsonb, uuid);
DROP FUNCTION IF EXISTS upsert_bundle(jsonb, uuid, uuid[]);
CREATE OR REPLACE FUNCTION upsert_bundle(
  p_bundle  jsonb,
  p_user_id uuid DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id      uuid;
  v_pid_txt text;
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
    source         = COALESCE(EXCLUDED.source,        bundles.source),
    project_id     = COALESCE(EXCLUDED.project_id,    bundles.project_id),
    user_id        = COALESCE(EXCLUDED.user_id,       bundles.user_id),
    session_shas   = COALESCE(EXCLUDED.session_shas,  bundles.session_shas),
    head_sha       = COALESCE(EXCLUDED.head_sha,      bundles.head_sha),
    exchange_count = GREATEST(EXCLUDED.exchange_count, bundles.exchange_count),
    items          = COALESCE(EXCLUDED.items,         bundles.items),
    pushed_at      = now(),
    updated_at     = now()
  RETURNING id INTO v_id;

  -- Write all touched projects to the junction table.
  -- touched_project_ids is a JSON string array inside p_bundle; iterate with
  -- jsonb_array_elements_text and cast each element to uuid explicitly.
  -- This avoids the uuid[] parameter type issue with PostgREST.
  FOR v_pid_txt IN
    SELECT jsonb_array_elements_text(p_bundle->'touched_project_ids')
  LOOP
    BEGIN
      INSERT INTO bundle_projects (bundle_id, project_id)
      VALUES (v_id, v_pid_txt::uuid)
      ON CONFLICT DO NOTHING;
    EXCEPTION
      WHEN invalid_text_representation THEN NULL; -- bad uuid string — skip
      WHEN foreign_key_violation       THEN NULL; -- project not in projects table — skip
    END;
  END LOOP;

  RETURN v_id::text;
END;
$$;
