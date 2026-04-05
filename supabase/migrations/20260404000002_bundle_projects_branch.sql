-- Add branch_name to bundle_projects.
-- Each repo a bundle touches can be on a different branch.
-- This replaces querying bundles.branch_name for per-project branch display.

ALTER TABLE bundle_projects ADD COLUMN IF NOT EXISTS branch_name text;

-- Backfill from bundles.branch_name for existing rows (primary project uses bundle's branch)
UPDATE bundle_projects bp
SET branch_name = b.branch_name
FROM bundles b
WHERE bp.bundle_id = b.id
  AND bp.is_primary = true
  AND b.branch_name IS NOT NULL;

-- Update upsert_bundle to accept per-project branch via touched_projects JSON array.
-- Each element: {"project_id": "uuid", "branch": "main", "is_primary": true}
-- Falls back to touched_project_ids (flat array) for backward compat.
DROP FUNCTION IF EXISTS upsert_bundle(jsonb, uuid);
CREATE OR REPLACE FUNCTION upsert_bundle(
  p_bundle  jsonb,
  p_user_id uuid DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id         uuid;
  v_proj       jsonb;
  v_pid_txt    text;
  v_branch_txt text;
  v_is_primary boolean;
  v_first      boolean := true;
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
    -- branch_name on bundles = primary project's branch (backward compat)
    (SELECT (elem->>'branch')
     FROM jsonb_array_elements(COALESCE(p_bundle->'touched_projects', '[]'::jsonb)) elem
     WHERE (elem->>'is_primary')::boolean = true
     LIMIT 1),
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
    branch_name    = COALESCE(EXCLUDED.branch_name,   bundles.branch_name),
    session_shas   = COALESCE(EXCLUDED.session_shas,  bundles.session_shas),
    head_sha       = COALESCE(EXCLUDED.head_sha,      bundles.head_sha),
    exchange_count = GREATEST(EXCLUDED.exchange_count, bundles.exchange_count),
    items          = COALESCE(EXCLUDED.items,         bundles.items),
    pushed_at      = now(),
    updated_at     = now()
  RETURNING id INTO v_id;

  -- Write bundle_projects with per-project branch_name.
  -- Prefers touched_projects (rich format); falls back to touched_project_ids (flat).
  IF jsonb_array_length(COALESCE(p_bundle->'touched_projects', '[]'::jsonb)) > 0 THEN
    FOR v_proj IN SELECT jsonb_array_elements(p_bundle->'touched_projects') LOOP
      v_pid_txt    := v_proj->>'project_id';
      v_branch_txt := v_proj->>'branch';
      v_is_primary := COALESCE((v_proj->>'is_primary')::boolean, false);
      BEGIN
        INSERT INTO bundle_projects (bundle_id, project_id, is_primary, branch_name)
        VALUES (v_id, v_pid_txt::uuid, v_is_primary, v_branch_txt)
        ON CONFLICT (bundle_id, project_id) DO UPDATE
          SET is_primary  = EXCLUDED.is_primary,
              branch_name = COALESCE(EXCLUDED.branch_name, bundle_projects.branch_name);
      EXCEPTION
        WHEN invalid_text_representation THEN NULL;
        WHEN foreign_key_violation       THEN NULL;
      END;
    END LOOP;
  ELSE
    -- Fallback: flat touched_project_ids array, no per-project branch
    FOR v_pid_txt IN SELECT jsonb_array_elements_text(p_bundle->'touched_project_ids') LOOP
      BEGIN
        INSERT INTO bundle_projects (bundle_id, project_id, is_primary, branch_name)
        VALUES (v_id, v_pid_txt::uuid, v_first, p_bundle->>'branch_name')
        ON CONFLICT (bundle_id, project_id) DO UPDATE
          SET is_primary  = EXCLUDED.is_primary,
              branch_name = COALESCE(EXCLUDED.branch_name, bundle_projects.branch_name);
        v_first := false;
      EXCEPTION
        WHEN invalid_text_representation THEN NULL;
        WHEN foreign_key_violation       THEN NULL;
      END;
    END LOOP;
  END IF;

  RETURN v_id::text;
END;
$$;
