-- Fix token tracking broken since 2026-02-23 when model_name was added to unique constraint
-- Problem: check_proxy_rate_limit old overload and increment_proxy_tokens used wrong ON CONFLICT

-- 1. Drop old overload of check_proxy_rate_limit (without model_name param)
DROP FUNCTION IF EXISTS public.check_proxy_rate_limit(text, integer);

-- 2. Drop old overload of increment_proxy_tokens (without model_name param)
DROP FUNCTION IF EXISTS public.increment_proxy_tokens(text, bigint, bigint, bigint);

-- 3. Recreate increment_proxy_tokens with model_name parameter
CREATE OR REPLACE FUNCTION public.increment_proxy_tokens(
  p_proxy_name text,
  p_prompt_tokens bigint,
  p_completion_tokens bigint,
  p_total_tokens bigint,
  p_model_name text DEFAULT 'unknown'
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID;
  v_today DATE;
BEGIN
  v_user_id := auth.uid();
  v_today := CURRENT_DATE;
  IF v_user_id IS NULL THEN RETURN; END IF;

  INSERT INTO public.proxy_daily_usage (
    user_id, usage_date, proxy_name, model_name, request_count,
    total_prompt_tokens, total_completion_tokens, total_tokens
  )
  VALUES (v_user_id, v_today, p_proxy_name, p_model_name, 0,
          p_prompt_tokens, p_completion_tokens, p_total_tokens)
  ON CONFLICT (user_id, usage_date, proxy_name, model_name)
  DO UPDATE SET
    total_prompt_tokens = proxy_daily_usage.total_prompt_tokens + EXCLUDED.total_prompt_tokens,
    total_completion_tokens = proxy_daily_usage.total_completion_tokens + EXCLUDED.total_completion_tokens,
    total_tokens = proxy_daily_usage.total_tokens + EXCLUDED.total_tokens;
END;
$$;

GRANT EXECUTE ON FUNCTION public.increment_proxy_tokens(text, bigint, bigint, bigint, text)
  TO anon, authenticated, service_role;
