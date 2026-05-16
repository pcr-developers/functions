-- ============================================================
-- Tags become strictly private — each user only ever sees their own.
--
-- Previously the SELECT policy on prompt_tags was permissive: any
-- project member could read any tag on a prompt in their project,
-- which made tagging feel like a public label-the-prompt action.
--
-- The product direction shifted to "tags are a personal annotation
-- layer" — like notes in a margin. They should never bleed across
-- users, even within the same project. RLS is the right place to
-- enforce this (the UI changes alone wouldn't prevent the data from
-- being fetched by anyone who hits the table directly).
--
-- INSERT and DELETE policies stay as-is: you can only insert as
-- yourself, and only delete your own (with admin override) — both of
-- which already match the "personal annotation" model.
-- ============================================================

DROP POLICY IF EXISTS "prompt_tags_select" ON prompt_tags;
CREATE POLICY "prompt_tags_select" ON prompt_tags
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());
