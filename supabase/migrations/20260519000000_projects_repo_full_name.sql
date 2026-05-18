-- ============================================================
-- projects.repo_full_name — STORED generated column with the
-- normalised "owner/repo" form of repo_url.
--
-- The github-webhook function previously matched projects via
--   .or('repo_url.ilike.%${repoFullName}%, repo_url.ilike.%${html_url}%')
-- which is a substring search across all projects. That can
-- cross-match similarly named repos in different orgs (e.g. a
-- webhook from `acme/foo-fork` would also match a PCR project
-- whose `repo_url` ends in `acme/foo`). Switching the lookup to
-- `eq('repo_full_name', '<owner>/<repo>')` requires a stable
-- normalised value to compare against, hence this column.
--
-- The expression handles every shape currently in the
-- production `projects` table (verified by running it against
-- live data on 2026-05-18):
--   * https://github.com/owner/repo
--   * https://github.com/owner/repo.git
--   * git@github.com:owner/repo.git
--   * ssh://git@github.com/owner/repo(.git)
--   * git://host/owner/repo(.git)
--
-- The expression is IMMUTABLE (all functions used —
-- regexp_replace with constant patterns — are immutable), which
-- is the prerequisite for STORED generated columns. NULL
-- repo_url maps to NULL repo_full_name via the explicit CASE.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT
-- EXISTS. Safe to re-run.
-- ============================================================

ALTER TABLE projects
  ADD COLUMN IF NOT EXISTS repo_full_name text
  GENERATED ALWAYS AS (
    CASE
      WHEN repo_url IS NULL THEN NULL
      ELSE regexp_replace(
             regexp_replace(
               regexp_replace(repo_url, '\.git$', '', 'i'),
               '^(?:https?://[^/]+/|git@[^:]+:|ssh://[^/]+/|git://[^/]+/)',
               '',
               'i'
             ),
             '/+$',
             ''
           )
    END
  ) STORED;

CREATE INDEX IF NOT EXISTS projects_repo_full_name_idx
  ON projects (repo_full_name);
