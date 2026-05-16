-- ============================================================
-- Profile + GitHub connection visibility for project members.
--
-- The Members tab on a project page joins project_members → profiles
-- (and project_members → github_connections) to surface each member's
-- name, email, avatar, and GitHub handle. Without these policies the
-- joins return null for everyone except the viewer, so the dashboard
-- falls back to rendering raw UUIDs in the member list.
--
-- The existing teams migration only granted profile visibility within
-- a shared *team*. This adds the parallel grant for projects: if you
-- share a project with someone, you can read their public profile +
-- GitHub link.
--
-- We reuse the `my_project_ids()` SECURITY DEFINER helper introduced
-- in `20260515000002_project_members_visibility.sql` to avoid the
-- "infinite recursion detected" trap when a policy ends up querying
-- project_members from inside another project_members-gated policy.
-- ============================================================

-- profiles ---------------------------------------------------------------
DROP POLICY IF EXISTS "profiles_select_by_project_member" ON profiles;
CREATE POLICY "profiles_select_by_project_member" ON profiles
  FOR SELECT TO authenticated
  USING (
    id = auth.uid()
    OR id IN (
      SELECT user_id FROM project_members
      WHERE project_id = ANY (public.my_project_ids())
    )
  );

-- github_connections -----------------------------------------------------
-- We tolerate the case where this table doesn't exist (older deployments)
-- and the case where RLS isn't enabled. The DO block lets the migration
-- run cleanly either way.
DO $github$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'github_connections'
  ) THEN
    EXECUTE 'ALTER TABLE github_connections ENABLE ROW LEVEL SECURITY';
    EXECUTE 'DROP POLICY IF EXISTS "github_connections_select_self" ON github_connections';
    EXECUTE $sql$
      CREATE POLICY "github_connections_select_self" ON github_connections
        FOR SELECT TO authenticated
        USING (user_id = auth.uid())
    $sql$;
    EXECUTE 'DROP POLICY IF EXISTS "github_connections_select_by_project_member" ON github_connections';
    EXECUTE $sql$
      CREATE POLICY "github_connections_select_by_project_member" ON github_connections
        FOR SELECT TO authenticated
        USING (
          user_id = auth.uid()
          OR user_id IN (
            SELECT user_id FROM project_members
            WHERE project_id = ANY (public.my_project_ids())
          )
        )
    $sql$;
  END IF;
END
$github$;
