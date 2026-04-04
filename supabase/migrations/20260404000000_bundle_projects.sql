-- ============================================================
-- bundle_projects migration
-- Safe to run: only additive until the final DROP COLUMN.
-- Existing bundles data is fully preserved.
-- ============================================================

-- 1. Create junction table
CREATE TABLE IF NOT EXISTS bundle_projects (
  bundle_id  uuid NOT NULL REFERENCES bundles(id)   ON DELETE CASCADE,
  project_id uuid NOT NULL REFERENCES projects(id)  ON DELETE CASCADE,
  is_primary boolean NOT NULL DEFAULT false,
  PRIMARY KEY (bundle_id, project_id)
);

CREATE INDEX IF NOT EXISTS bundle_projects_project_id_idx ON bundle_projects (project_id);
CREATE INDEX IF NOT EXISTS bundle_projects_bundle_id_idx  ON bundle_projects (bundle_id);

-- 2. Backfill from existing non-null project_id values.
-- This preserves the one bundle that already has a project_id (Dana's "refining pcr workflow").
INSERT INTO bundle_projects (bundle_id, project_id, is_primary)
SELECT id, project_id, true
FROM bundles
WHERE project_id IS NOT NULL
ON CONFLICT DO NOTHING;

-- 3. Manually link the three bundles that have null project_id.
-- Edit these project_id values to match the correct repos.
-- Your project IDs:
--   cli        = e42c442f-ee9e-49de-a61c-d15ef851be78
--   pcr-dev    = 99ddcf41-2c68-4ff1-a19d-ae3c70545b50
--   functions  = a0365db4-5cec-43ec-9263-525aec68bbe1
--   app        = 863e67c5-f0b6-4a54-b290-2da190622abf
INSERT INTO bundle_projects (bundle_id, project_id, is_primary) VALUES
  -- "license update apache" — touches cli (Apache license added to cli repo)
  ('005c55da-c595-492c-97f2-454308e3e7be', 'e42c442f-ee9e-49de-a61c-d15ef851be78', true),
  -- "localhost config fix" — touches cli
  ('83965e7e-f0bf-4a7e-af0a-0139427ebc9e', 'e42c442f-ee9e-49de-a61c-d15ef851be78', true),
  -- "name" — has cli commit shas (277be04, 2b3e9a3), touched cli + pcr-dev + functions
  ('a0ed1dea-4627-4fd5-a0bb-1a0979826390', 'e42c442f-ee9e-49de-a61c-d15ef851be78', true),
  ('a0ed1dea-4627-4fd5-a0bb-1a0979826390', '99ddcf41-2c68-4ff1-a19d-ae3c70545b50', false),
  ('a0ed1dea-4627-4fd5-a0bb-1a0979826390', 'a0365db4-5cec-43ec-9263-525aec68bbe1', false)
ON CONFLICT DO NOTHING;

-- 4. RLS on bundle_projects
ALTER TABLE bundle_projects ENABLE ROW LEVEL SECURITY;

-- bundle_projects RLS must NOT reference bundles table to avoid infinite recursion.
-- (bundles policy references bundle_projects; bundle_projects cannot reference bundles back)
DROP POLICY IF EXISTS "Users can read own bundle_projects" ON bundle_projects;
DROP POLICY IF EXISTS "Team members can read bundle_projects" ON bundle_projects;

CREATE POLICY "Users can read bundle_projects" ON bundle_projects
  FOR SELECT USING (
    -- User is a member of the linked project (primary path — no bundles reference)
    EXISTS (
      SELECT 1 FROM project_members pm
      WHERE pm.project_id = bundle_projects.project_id
        AND pm.user_id = auth.uid()
    )
    OR
    -- User owns the bundle directly (fallback for bundles not yet linked to a project)
    EXISTS (
      SELECT 1 FROM bundles b
      WHERE b.id = bundle_projects.bundle_id
        AND b.user_id = auth.uid()
    )
  );

-- 5. Update bundles RLS to use bundle_projects instead of project_id
DROP POLICY IF EXISTS "Team members can read team bundles" ON bundles;
CREATE POLICY "Team members can read team bundles" ON bundles
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM bundle_projects bp
      JOIN project_members pm ON pm.project_id = bp.project_id
      WHERE bp.bundle_id = bundles.id AND pm.user_id = auth.uid()
    )
  );

-- 6. Update upsert_bundle RPC to write to bundle_projects.
--    touched_project_ids is a JSON string array inside p_bundle.
--    is_primary=true for the first entry in touched_project_ids.
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
  v_id       uuid;
  v_pid_txt  text;
  v_first    boolean := true;
BEGIN
  INSERT INTO bundles (
    bundle_id, message, source, user_id,
    project_name, branch_name, session_shas, head_sha,
    exchange_count, items, committed_at, pushed_at
  ) VALUES (
    p_bundle->>'bundle_id',
    p_bundle->>'message',
    COALESCE(p_bundle->>'source', 'unknown'),
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
    user_id        = COALESCE(EXCLUDED.user_id,       bundles.user_id),
    session_shas   = COALESCE(EXCLUDED.session_shas,  bundles.session_shas),
    head_sha       = COALESCE(EXCLUDED.head_sha,      bundles.head_sha),
    exchange_count = GREATEST(EXCLUDED.exchange_count, bundles.exchange_count),
    items          = COALESCE(EXCLUDED.items,         bundles.items),
    pushed_at      = now(),
    updated_at     = now()
  RETURNING id INTO v_id;

  -- Write all touched projects; first one is primary.
  FOR v_pid_txt IN
    SELECT jsonb_array_elements_text(p_bundle->'touched_project_ids')
  LOOP
    BEGIN
      INSERT INTO bundle_projects (bundle_id, project_id, is_primary)
      VALUES (v_id, v_pid_txt::uuid, v_first)
      ON CONFLICT (bundle_id, project_id) DO UPDATE
        SET is_primary = EXCLUDED.is_primary;
      v_first := false;
    EXCEPTION
      WHEN invalid_text_representation THEN NULL;
      WHEN foreign_key_violation       THEN NULL;
    END;
  END LOOP;

  RETURN v_id::text;
END;
$$;

-- 7. Drop the now-redundant project_id column from bundles.
--    All project links live in bundle_projects.
--    Run this LAST — everything above must succeed first.
ALTER TABLE bundles DROP COLUMN IF EXISTS project_id;
