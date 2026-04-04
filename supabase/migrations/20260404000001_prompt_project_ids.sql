-- Add project_ids uuid[] to prompts.
-- Each row stores only the repos that specific prompt actually touched,
-- as determined by DiffTracker at capture time.
-- No backfill — historical prompts without DiffTracker data stay empty.

ALTER TABLE prompts ADD COLUMN IF NOT EXISTS project_ids uuid[] DEFAULT '{}';

CREATE INDEX IF NOT EXISTS prompts_project_ids_gin ON prompts USING GIN (project_ids);

-- Update upsert_prompts to populate project_ids from the record payload.
-- The CLI sends project_ids as a JSON array of uuid strings per prompt.
CREATE OR REPLACE FUNCTION upsert_prompts(p_records jsonb, p_user_id uuid DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  rec        jsonb;
  v_proj_ids uuid[];
  v_pid_txt  text;
  inserted   integer := 0;
BEGIN
  FOR rec IN SELECT jsonb_array_elements(p_records) LOOP

    -- Build project_ids from rec.project_ids (preferred) or fallback to rec.project_id
    v_proj_ids := '{}';
    IF rec->'project_ids' IS NOT NULL AND jsonb_typeof(rec->'project_ids') = 'array' THEN
      FOR v_pid_txt IN SELECT jsonb_array_elements_text(rec->'project_ids') LOOP
        BEGIN
          v_proj_ids := array_append(v_proj_ids, v_pid_txt::uuid);
        EXCEPTION WHEN invalid_text_representation THEN NULL;
        END;
      END LOOP;
    ELSIF rec->>'project_id' IS NOT NULL THEN
      BEGIN
        v_proj_ids := ARRAY[(rec->>'project_id')::uuid];
      EXCEPTION WHEN invalid_text_representation THEN NULL;
      END;
    END IF;

    INSERT INTO prompts (
      id, content_hash, session_id, project_id, project_ids,
      project_name, branch_name, prompt_text, response_text,
      model, source, capture_method, tool_calls, file_context,
      captured_at, user_id, bundle_id
    ) VALUES (
      COALESCE((rec->>'id')::uuid, gen_random_uuid()),
      rec->>'content_hash',
      rec->>'session_id',
      (rec->>'project_id')::uuid,
      v_proj_ids,
      rec->>'project_name',
      rec->>'branch_name',
      rec->>'prompt_text',
      rec->>'response_text',
      rec->>'model',
      COALESCE(rec->>'source', 'unknown'),
      COALESCE(rec->>'capture_method', 'file-watcher'),
      rec->'tool_calls',
      rec->'file_context',
      COALESCE((rec->>'captured_at')::timestamptz, now()),
      COALESCE(p_user_id, (rec->>'user_id')::uuid),
      rec->>'bundle_id'
    )
    ON CONFLICT (content_hash) DO UPDATE SET
      response_text = COALESCE(EXCLUDED.response_text, prompts.response_text),
      tool_calls    = COALESCE(EXCLUDED.tool_calls,    prompts.tool_calls),
      file_context  = COALESCE(EXCLUDED.file_context,  prompts.file_context),
      model         = COALESCE(EXCLUDED.model,          prompts.model),
      bundle_id     = COALESCE(EXCLUDED.bundle_id,      prompts.bundle_id),
      project_ids   = CASE
                        WHEN EXCLUDED.project_ids <> '{}' THEN EXCLUDED.project_ids
                        ELSE prompts.project_ids
                      END;

    inserted := inserted + 1;
  END LOOP;
  RETURN inserted;
END;
$$;
