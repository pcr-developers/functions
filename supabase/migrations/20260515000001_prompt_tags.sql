-- ============================================================
-- prompt_tags — personal, attributed prompt tags.
--
-- Replaces the flat `prompts.tags text[]` column with a proper join
-- table so:
--   * Each tag is owned by the user who added it (avatar + autocomplete).
--   * Multiple users can tag the same prompt without overwriting.
--   * Per-user, per-project autocomplete is fast (single index lookup).
--   * Tags survive prompt deletes via FK CASCADE rather than living in a
--     mutable jsonb blob.
--
-- The original `prompts.tags` column is *kept* (not dropped) for backwards
-- compatibility with anything still reading it; the dashboard UI moves to
-- the new table and stops writing to the old column.
-- ============================================================

CREATE TABLE IF NOT EXISTS prompt_tags (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  prompt_id  uuid NOT NULL REFERENCES prompts(id)   ON DELETE CASCADE,
  project_id uuid          REFERENCES projects(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tag        text NOT NULL
             CHECK (length(btrim(tag)) > 0 AND length(tag) <= 50),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (prompt_id, user_id, tag)
);

-- Fast paths:
--   * Fetch every tag on a prompt (display).
--   * Suggest a single user's tags within a project (autocomplete).
--   * Filter all prompts in a project that carry a specific tag.
CREATE INDEX IF NOT EXISTS prompt_tags_prompt_id_idx
  ON prompt_tags (prompt_id);
CREATE INDEX IF NOT EXISTS prompt_tags_user_project_idx
  ON prompt_tags (user_id, project_id);
CREATE INDEX IF NOT EXISTS prompt_tags_project_tag_idx
  ON prompt_tags (project_id, tag);

ALTER TABLE prompt_tags ENABLE ROW LEVEL SECURITY;

-- SELECT — anyone with access to the prompt's project can read its tags.
-- We rely on project_members for visibility, matching the new "Project
-- members can read team prompts" policy from the previous migration.
DROP POLICY IF EXISTS "prompt_tags_select" ON prompt_tags;
CREATE POLICY "prompt_tags_select" ON prompt_tags
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM project_members pm
      WHERE pm.project_id = prompt_tags.project_id
        AND pm.user_id = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM prompts p
      WHERE p.id = prompt_tags.prompt_id
        AND p.user_id = auth.uid()
    )
  );

-- INSERT — you can only tag *as yourself*, and only on prompts you can see.
DROP POLICY IF EXISTS "prompt_tags_insert" ON prompt_tags;
CREATE POLICY "prompt_tags_insert" ON prompt_tags
  FOR INSERT TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND (
      EXISTS (
        SELECT 1 FROM project_members pm
        WHERE pm.project_id = prompt_tags.project_id
          AND pm.user_id = auth.uid()
      )
      OR EXISTS (
        SELECT 1 FROM prompts p
        WHERE p.id = prompt_tags.prompt_id
          AND p.user_id = auth.uid()
      )
    )
  );

-- DELETE — you can remove your own tags, and project admins/owners can
-- remove anyone's (useful for cleaning up).
DROP POLICY IF EXISTS "prompt_tags_delete" ON prompt_tags;
CREATE POLICY "prompt_tags_delete" ON prompt_tags
  FOR DELETE TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM project_members pm
      WHERE pm.project_id = prompt_tags.project_id
        AND pm.user_id = auth.uid()
        AND pm.role IN ('owner', 'admin')
    )
  );

-- ─── Backfill ───────────────────────────────────────────────────────────
-- Migrate existing `prompts.tags` (the legacy flat array) into the
-- attributed table. We credit the prompt's capturer (`prompts.user_id`)
-- as the author. Prompts with a NULL `user_id` are skipped — we'd have
-- nothing meaningful to attribute them to. The unique key drops dupes
-- on re-run.
--
-- Wrapped in a DO block so this migration is independent of the
-- earlier `20260515000000` one: if `prompts.tags` doesn't exist yet
-- (legacy column never added, or migrations applied out of order)
-- we silently skip the backfill instead of failing the whole script.
DO $migrate$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'prompts'
      AND column_name  = 'tags'
  ) THEN
    EXECUTE $sql$
      INSERT INTO prompt_tags (prompt_id, project_id, user_id, tag)
      SELECT
        p.id,
        p.project_id,
        p.user_id,
        btrim(t.tag)
      FROM prompts p
      CROSS JOIN LATERAL unnest(COALESCE(p.tags, '{}'::text[])) AS t(tag)
      WHERE p.user_id IS NOT NULL
        AND btrim(t.tag) <> ''
      ON CONFLICT (prompt_id, user_id, tag) DO NOTHING
    $sql$;
  END IF;
END
$migrate$;
