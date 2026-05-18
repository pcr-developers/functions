-- ============================================================
-- set_sessions_pr_batch — batched variant of set_session_pr.
--
-- The github-webhook function previously issued one
-- `set_session_pr` RPC per matched cursor session inside a
-- Promise.all loop. That's N round trips per webhook delivery
-- and noisy in DB / function logs. This RPC collapses all of
-- them into a single UPDATE.
--
-- Body, signature, security model and grants all mirror the
-- existing `set_session_pr` (LANGUAGE plpgsql, SECURITY DEFINER,
-- no SET search_path, default grants) — see
-- `pg_get_functiondef('set_session_pr')`. The only deltas:
--   * param 1 is text[] instead of text (session_id is a text
--     column in cursor_sessions despite being a UUID by
--     convention; matching the column type avoids a cast)
--   * the WHERE clause is `session_id = ANY(p_session_ids)`
--
-- Idempotent: CREATE OR REPLACE FUNCTION.
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_sessions_pr_batch(
  p_session_ids text[],
  p_pr_number   integer,
  p_pr_url      text,
  p_comment_id  bigint
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  UPDATE cursor_sessions
     SET github_pr_number     = p_pr_number,
         github_pr_url        = p_pr_url,
         github_pr_comment_id = p_comment_id,
         updated_at           = now()
   WHERE session_id = ANY(p_session_ids);
END;
$$;
