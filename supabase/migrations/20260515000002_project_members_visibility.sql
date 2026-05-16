-- ============================================================
-- Widen `project_members` SELECT to "all members of my projects",
-- not "only my own row".
--
-- Without this, the dashboard's Members tab only ever shows the
-- viewer themselves — even after teammates are inserted via SQL
-- or via the new "User ID" invite tab, the other rows are hidden
-- by RLS.
--
-- We avoid the standard infinite-recursion trap (a project_members
-- policy that subqueries project_members) by routing the lookup
-- through a SECURITY DEFINER helper, mirroring the `my_team_id()`
-- pattern used by the teams migration.
-- ============================================================

CREATE OR REPLACE FUNCTION public.my_project_ids()
RETURNS uuid[]
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(array_agg(project_id), '{}'::uuid[])
  FROM project_members
  WHERE user_id = auth.uid();
$$;

-- Clear out any prior SELECT policies on project_members so we end
-- with a single, well-named policy. Names varied across older
-- migrations — we drop the common candidates idempotently.
DROP POLICY IF EXISTS "project_members_select"          ON project_members;
DROP POLICY IF EXISTS "Users can view project members"  ON project_members;
DROP POLICY IF EXISTS "Users can read project_members"  ON project_members;
DROP POLICY IF EXISTS "project_members_select_visible"  ON project_members;

CREATE POLICY "project_members_select_visible" ON project_members
  FOR SELECT TO authenticated
  USING (
    -- Always see my own row.
    user_id = auth.uid()
    -- Plus every row in a project I'm also a member of.
    OR project_id = ANY (public.my_project_ids())
  );
