-- ============================================================
-- prompt_tags.polarity — curated review-label polarity.
--
-- The web review surface ships a curated set of "suggested labels"
-- (research-backed prompt patterns / antipatterns) on top of the
-- existing freeform `prompt_tags.tag` column. The user-visible string
-- still lives in `tag` (localized at write time so a French reviewer
-- writes "Intention claire" and a German one "Klare Absicht"); the
-- polarity is what drives chip color and the "good vs bad" semantics
-- across the codebase, so it can't live in the localized string.
--
--   * polarity = 'pattern'      — positive, "enforce this".
--   * polarity = 'antipattern'  — negative, "fix this".
--   * polarity = NULL           — freeform user tag (the existing
--                                 behavior, unchanged).
--
-- Idempotent: safe to re-run. RLS is intentionally untouched — the
-- existing SELECT / INSERT / DELETE policies on prompt_tags continue
-- to gate access (user_id ownership + project membership), and they
-- already work column-agnostically.
-- ============================================================

ALTER TABLE prompt_tags
  ADD COLUMN IF NOT EXISTS polarity text;

-- Add the CHECK constraint defensively. Postgres has no native
-- IF NOT EXISTS for table constraints, so we wrap it in a DO block.
-- We also drop-then-recreate to make the constraint shape match the
-- current spec on every apply (cheap, since the table is small).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'prompt_tags_polarity_check'
  ) THEN
    ALTER TABLE prompt_tags DROP CONSTRAINT prompt_tags_polarity_check;
  END IF;
END
$$;

ALTER TABLE prompt_tags
  ADD CONSTRAINT prompt_tags_polarity_check
  CHECK (polarity IN ('pattern', 'antipattern'));
