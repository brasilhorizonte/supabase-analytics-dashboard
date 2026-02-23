-- Migration: Update get_analytics_data() to GROUP BY model_name
-- Apply to: Horizon Terminal Access (llqhmywodxzstjlrulcw)
-- Changes: token_usage_daily, token_usage_summary, token_usage_by_user now include model_name

-- See full RPC in apply_migration call (too large to duplicate here)
-- Key changes:
--   token_usage_daily: GROUP BY usage_date, proxy_name, model_name
--   token_usage_summary: GROUP BY proxy_name, model_name
--   token_usage_by_user: GROUP BY p.user_id, u.email, p.proxy_name, p.model_name
