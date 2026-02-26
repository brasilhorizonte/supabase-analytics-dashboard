-- ========================================
-- Migration: Proxy Error Metrics
-- Date: 2026-02-26
-- Adds: proxy_error_log table, error_count column, log_proxy_error RPC,
--        and 3 new analytics sections in get_analytics_data()
-- ========================================

-- 1a. New table: proxy_error_log
CREATE TABLE IF NOT EXISTS public.proxy_error_log (
  id bigserial PRIMARY KEY,
  user_id uuid NOT NULL,
  proxy_name text NOT NULL,
  model_name text NOT NULL DEFAULT 'unknown',
  error_type text NOT NULL,
  status_code integer,
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_proxy_error_log_date ON public.proxy_error_log (created_at);
CREATE INDEX IF NOT EXISTS idx_proxy_error_log_proxy ON public.proxy_error_log (proxy_name, created_at);

-- RLS disabled (accessed only via SECURITY DEFINER functions)
ALTER TABLE public.proxy_error_log ENABLE ROW LEVEL SECURITY;

-- 1b. Add error_count column to proxy_daily_usage
ALTER TABLE public.proxy_daily_usage ADD COLUMN IF NOT EXISTS error_count integer NOT NULL DEFAULT 0;

-- 1c. RPC: log_proxy_error
CREATE OR REPLACE FUNCTION public.log_proxy_error(
  p_user_id uuid,
  p_proxy_name text,
  p_model_name text DEFAULT 'unknown',
  p_error_type text DEFAULT 'unknown',
  p_status_code integer DEFAULT NULL,
  p_error_message text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.proxy_error_log (user_id, proxy_name, model_name, error_type, status_code, error_message)
  VALUES (p_user_id, p_proxy_name, p_model_name, p_error_type, p_status_code, left(p_error_message, 500));

  INSERT INTO public.proxy_daily_usage (user_id, usage_date, proxy_name, model_name, request_count, error_count,
    total_prompt_tokens, total_completion_tokens, total_tokens)
  VALUES (p_user_id, CURRENT_DATE, p_proxy_name, p_model_name, 0, 1, 0, 0, 0)
  ON CONFLICT (user_id, usage_date, proxy_name, model_name)
  DO UPDATE SET error_count = proxy_daily_usage.error_count + 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.log_proxy_error(uuid, text, text, text, integer, text) TO anon, authenticated, service_role;
