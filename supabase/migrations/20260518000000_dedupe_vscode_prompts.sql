-- ============================================================
-- Dedupe VS Code prompts created by the dual-watch capture bug.
--
-- VS Code Copilot Chat 0.45+ writes the same conversation to BOTH
-- `.../GitHub.copilot-chat/transcripts/<sid>.jsonl` (legacy) AND
-- `.../chatSessions/<sid>.jsonl` (modern) during the version-upgrade
-- window. The CLI watcher used to register notify watches on both
-- directories and dispatch the same prompt through two different
-- parsers:
--
--   * The legacy `parse_transcript` keeps VS Code's raw timestamp
--     string as `captured_at` (e.g. `2026-05-11T10:52:23.123Z`).
--   * The modern `parse_chatsession` reformats via `SecondsFormat::Millis`
--     (e.g. also `2026-05-11T10:52:23.123Z` — but the legacy file
--     occasionally carries microsecond precision or a non-Z offset).
--
-- The V2 `content_hash` is `sha256(session_id || \x00 || prompt_text
-- || \x00 || captured_at)`, so a microsecond difference in `captured_at`
-- formatting produced two distinct hashes for the same exchange. The
-- unique constraint on `prompts.content_hash` couldn't dedupe them, so
-- the bundle review page rendered the same prompt twice (e.g. prompts
-- 8 and 9 both showing "the water missed the seed / 3 tools" on the
-- same session).
--
-- The CLI fix landed in the dual-watch removal commit (see CLI
-- diagnosis 2026-05-17): the watcher now prefers `chatSessions/`
-- whenever it exists, and `prompt_content_hash_v2` normalises
-- `captured_at` to canonical UTC-millis before hashing so both
-- pipelines converge to the same hash going forward.
--
-- This migration cleans up the rows that were already double-written
-- before the fix shipped. For each `(session_id, prompt_text)` pair
-- in the `vscode` source, it keeps the OLDEST row and deletes the
-- rest. The oldest row is preferred because it almost always has the
-- complete tool_calls / response_text payload (the legacy parser
-- streams as the conversation happens; the chatSessions snapshot
-- often lands later as a single rewrite).
--
-- Idempotent: re-running on a deduped table is a no-op (the CTE finds
-- no row with `rn > 1`). Wrapped in an explicit transaction so the
-- count notice and the DELETE are atomic.
-- ============================================================

BEGIN;

DO $$
DECLARE
  dup_count integer;
BEGIN
  SELECT COUNT(*) INTO dup_count
  FROM (
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY session_id, prompt_text
             ORDER BY created_at, id
           ) AS rn
    FROM prompts
    WHERE source = 'vscode'
      AND session_id IS NOT NULL
  ) ranked
  WHERE rn > 1;

  RAISE NOTICE 'dedupe_vscode_prompts: % duplicate rows will be deleted', dup_count;
END
$$;

WITH ranked AS (
  SELECT id,
         ROW_NUMBER() OVER (
           PARTITION BY session_id, prompt_text
           ORDER BY created_at, id
         ) AS rn
  FROM prompts
  WHERE source = 'vscode'
    AND session_id IS NOT NULL
)
DELETE FROM prompts
WHERE id IN (
  SELECT id FROM ranked WHERE rn > 1
);

COMMIT;
