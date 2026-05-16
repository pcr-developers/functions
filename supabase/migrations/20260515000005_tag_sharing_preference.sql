-- ============================================================
-- Optional tag sharing.
--
-- Each user can flip a per-account opt-in to make their personal
-- prompt tags visible to other members of any shared project. The
-- default stays "off" — tags remain private unless the user
-- deliberately enables sharing in their settings page.
--
-- We widen the SELECT policy on prompt_tags to honour the opt-in:
--
--   * I always see my own tags.
--   * I see another user's tag iff
--       1. they have `user_preferences.share_tags = true`, AND
--       2. the tag is on a prompt in a project we both belong to.
--
-- The shared-flag lookup is wrapped in a SECURITY DEFINER helper so
-- the prompt_tags policy can read it for an arbitrary `user_id`
-- (user_preferences's own RLS only allows reading your own row).
-- The "am I a member of this project" check reuses the existing
-- `my_project_ids()` helper for the same reason.
-- ============================================================

-- The `user_preferences` table is normally created by an earlier
-- migration (`20260323000001_user_preferences.sql`). We re-declare
-- it here with `IF NOT EXISTS` so this migration is safe to apply
-- against deployments where that earlier file was never run. The
-- columns/policies match the original file 1:1; the `share_tags`
-- column we actually care about is added via `ADD COLUMN IF NOT
-- EXISTS` below so an existing table doesn't get clobbered.
-- Note: the original migration constrained `theme` to a fixed set
-- (`'light' | 'dark' | 'system'`). The dashboard has since added a
-- `'brand'` option, so we deliberately omit the CHECK here — the
-- application enforces valid theme values, and a divergent DB-side
-- constraint would silently break the theme toggle in the navbar.
CREATE TABLE IF NOT EXISTS public.user_preferences (
  user_id      uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  theme        text NOT NULL DEFAULT 'brand',
  display_name text,
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- If the table already existed with the old CHECK, relax it now so
-- saving `theme = 'brand'` doesn't fail. Dropping a constraint by
-- name is idempotent — no-op if it isn't there.
ALTER TABLE public.user_preferences
  DROP CONSTRAINT IF EXISTS user_preferences_theme_check;

ALTER TABLE public.user_preferences ENABLE ROW LEVEL SECURITY;

DO $bootstrap$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_preferences'
      AND policyname = 'user_preferences_select'
  ) THEN
    EXECUTE $sql$
      CREATE POLICY "user_preferences_select" ON public.user_preferences
        FOR SELECT TO authenticated
        USING (user_id = auth.uid())
    $sql$;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_preferences'
      AND policyname = 'user_preferences_insert'
  ) THEN
    EXECUTE $sql$
      CREATE POLICY "user_preferences_insert" ON public.user_preferences
        FOR INSERT TO authenticated
        WITH CHECK (user_id = auth.uid())
    $sql$;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_preferences'
      AND policyname = 'user_preferences_update'
  ) THEN
    EXECUTE $sql$
      CREATE POLICY "user_preferences_update" ON public.user_preferences
        FOR UPDATE TO authenticated
        USING (user_id = auth.uid())
    $sql$;
  END IF;
END
$bootstrap$;

-- The actual feature: the per-user opt-in column.
ALTER TABLE user_preferences
  ADD COLUMN IF NOT EXISTS share_tags boolean NOT NULL DEFAULT false;

-- Read-only helper — never returns more than a single boolean. Stable
-- so Postgres can cache the call per query. Security definer so it
-- can see other users' preferences rows without breaking user_preferences's
-- "row-per-user" SELECT policy.
CREATE OR REPLACE FUNCTION public.user_shares_tags(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT share_tags FROM user_preferences WHERE user_id = p_user_id LIMIT 1),
    false
  );
$$;

DROP POLICY IF EXISTS "prompt_tags_select" ON prompt_tags;
CREATE POLICY "prompt_tags_select" ON prompt_tags
  FOR SELECT TO authenticated
  USING (
    -- My own tags — always.
    user_id = auth.uid()
    -- Or: tag author has opted in AND we share a project.
    OR (
      public.user_shares_tags(prompt_tags.user_id)
      AND prompt_tags.project_id = ANY (public.my_project_ids())
    )
  );
