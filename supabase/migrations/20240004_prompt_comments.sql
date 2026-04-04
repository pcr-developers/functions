-- prompt_comments: per-prompt inline review comments.
-- Team members who can see a prompt can comment on it.

CREATE TABLE IF NOT EXISTS prompt_comments (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  prompt_id  uuid NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  body       text NOT NULL CHECK (char_length(body) > 0 AND char_length(body) <= 4000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS prompt_comments_prompt_id_idx ON prompt_comments (prompt_id);
CREATE INDEX IF NOT EXISTS prompt_comments_user_id_idx   ON prompt_comments (user_id);

ALTER TABLE prompt_comments ENABLE ROW LEVEL SECURITY;

ALTER TABLE prompt_comments
ADD CONSTRAINT fk_user
FOREIGN KEY (user_id)
REFERENCES profiles(id);

DROP POLICY IF EXISTS "Users can read own comments" ON prompt_comments;
CREATE POLICY "Users can read own comments"
  ON prompt_comments FOR SELECT
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Team members can read comments" ON prompt_comments;
CREATE POLICY "Team members can read comments"
  ON prompt_comments FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM prompts p
      JOIN project_members pm ON pm.project_id = p.project_id
      WHERE p.id = prompt_comments.prompt_id AND pm.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Team members can insert comments" ON prompt_comments;
CREATE POLICY "Team members can insert comments"
  ON prompt_comments FOR INSERT
  WITH CHECK (
    user_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM prompts p
      JOIN project_members pm ON pm.project_id = p.project_id
      WHERE p.id = prompt_comments.prompt_id AND pm.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Users can update own comments" ON prompt_comments;
CREATE POLICY "Users can update own comments"
  ON prompt_comments FOR UPDATE
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can delete own comments" ON prompt_comments;
CREATE POLICY "Users can delete own comments"
  ON prompt_comments FOR DELETE
  USING (user_id = auth.uid());

-- Team-member read access to claude_bundles
DROP POLICY IF EXISTS "Team members can read team bundles" ON claude_bundles;
CREATE POLICY "Team members can read team bundles"
  ON claude_bundles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM project_members pm
      WHERE pm.project_id = claude_bundles.project_id AND pm.user_id = auth.uid()
    )
  );

-- Team-member read access to prompts
DROP POLICY IF EXISTS "Team members can read team prompts" ON prompts;
CREATE POLICY "Team members can read team prompts"
  ON prompts FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM project_members pm
      WHERE pm.project_id = prompts.project_id AND pm.user_id = auth.uid()
    )
  );

-- Team-member read access to git_diffs
DROP POLICY IF EXISTS "Team members can read team git diffs" ON git_diffs;
CREATE POLICY "Team members can read team git diffs"
  ON git_diffs FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM prompts p
      JOIN project_members pm ON pm.project_id = p.project_id
      WHERE p.id = git_diffs.prompt_id AND pm.user_id = auth.uid()
    )
  );

-- Index for timeline tab query: all prompts on a branch ordered by time
CREATE INDEX IF NOT EXISTS prompts_project_branch_time_idx
  ON prompts (project_id, branch_name, captured_at);
