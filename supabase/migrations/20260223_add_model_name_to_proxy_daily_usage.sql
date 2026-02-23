-- Migration: Add model_name to proxy_daily_usage
-- Apply to: Horizon Terminal Access (llqhmywodxzstjlrulcw)
-- Adds model_name column, updates unique constraint, updates RPCs

-- 1. Adicionar coluna model_name
ALTER TABLE public.proxy_daily_usage ADD COLUMN model_name text NOT NULL DEFAULT 'unknown';

-- 2. Backfill dados existentes (tudo era gemini-2.5-pro)
UPDATE public.proxy_daily_usage SET model_name = 'gemini-2.5-pro' WHERE proxy_name = 'gemini';

-- 3. Atualizar unique constraint para incluir model_name
ALTER TABLE public.proxy_daily_usage DROP CONSTRAINT proxy_daily_usage_unique;
ALTER TABLE public.proxy_daily_usage ADD CONSTRAINT proxy_daily_usage_unique
  UNIQUE (user_id, usage_date, proxy_name, model_name);

-- 4. Atualizar index de lookup
DROP INDEX IF EXISTS idx_proxy_daily_usage_lookup;
CREATE INDEX idx_proxy_daily_usage_lookup
  ON public.proxy_daily_usage (user_id, usage_date, proxy_name, model_name);

-- 5. Atualizar check_proxy_rate_limit: aceita model_name, rate limit agrega por proxy (nao modelo)
CREATE OR REPLACE FUNCTION public.check_proxy_rate_limit(
  p_proxy_name text,
  p_daily_limit integer,
  p_model_name text DEFAULT 'unknown'
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_today DATE;
  v_count INTEGER;
BEGIN
  v_user_id := auth.uid();
  v_today := CURRENT_DATE;

  IF v_user_id IS NULL THEN
    RETURN json_build_object(
      'error', 'Not authenticated',
      'request_count', 0,
      'daily_limit', p_daily_limit,
      'allowed', false
    );
  END IF;

  -- Atomic upsert: insert or increment (agora inclui model_name na key)
  INSERT INTO public.proxy_daily_usage (user_id, usage_date, proxy_name, model_name, request_count)
  VALUES (v_user_id, v_today, p_proxy_name, p_model_name, 1)
  ON CONFLICT (user_id, usage_date, proxy_name, model_name)
  DO UPDATE SET request_count = proxy_daily_usage.request_count + 1,
                updated_at = now()
  RETURNING request_count INTO v_count;

  -- Rate limit: aggregate across ALL models for the same proxy_name
  SELECT COALESCE(SUM(request_count), 0) INTO v_count
  FROM public.proxy_daily_usage
  WHERE user_id = v_user_id AND usage_date = v_today AND proxy_name = p_proxy_name;

  RETURN json_build_object(
    'request_count', v_count,
    'daily_limit', p_daily_limit,
    'remaining', GREATEST(0, p_daily_limit - v_count),
    'allowed', v_count <= p_daily_limit
  );
END;
$$;

-- 6. Atualizar increment_proxy_tokens: aceita model_name
CREATE OR REPLACE FUNCTION public.increment_proxy_tokens(
  p_proxy_name text,
  p_prompt_tokens bigint,
  p_completion_tokens bigint,
  p_total_tokens bigint,
  p_model_name text DEFAULT 'unknown'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_today DATE;
BEGIN
  v_user_id := auth.uid();
  v_today := CURRENT_DATE;

  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  -- Upsert: cria registro se nao existe, senao incrementa tokens
  INSERT INTO public.proxy_daily_usage (
    user_id, usage_date, proxy_name, model_name, request_count,
    total_prompt_tokens, total_completion_tokens, total_tokens
  )
  VALUES (v_user_id, v_today, p_proxy_name, p_model_name, 0, p_prompt_tokens, p_completion_tokens, p_total_tokens)
  ON CONFLICT (user_id, usage_date, proxy_name, model_name)
  DO UPDATE SET
    total_prompt_tokens = proxy_daily_usage.total_prompt_tokens + EXCLUDED.total_prompt_tokens,
    total_completion_tokens = proxy_daily_usage.total_completion_tokens + EXCLUDED.total_completion_tokens,
    total_tokens = proxy_daily_usage.total_tokens + EXCLUDED.total_tokens,
    updated_at = now();
END;
$$;

-- 7. Garantir grants
GRANT EXECUTE ON FUNCTION public.check_proxy_rate_limit(text, integer, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.increment_proxy_tokens(text, bigint, bigint, bigint, text) TO anon, authenticated, service_role;
