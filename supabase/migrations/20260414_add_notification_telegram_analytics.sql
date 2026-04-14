-- Notification & Telegram Analytics for BH Dashboard
-- Applied to BH project (dawvgbopyemcayavcatd) via execute_sql
--
-- Adds notification and telegram metrics to get_analytics_data() return JSON:
--   notifications_by_type_daily  — daily count by alert_type
--   notifications_delivery       — total / read / telegram_delivered breakdown
--   notifications_top_tickers    — top 20 tickers by notification volume
--   telegram_overview            — links active/inactive/total, linked users
--   telegram_links_daily         — new links per day
--   notification_funnel          — adoption funnel (users → notified → read → prefs → telegram)
--   notification_prefs_summary   — enabled %, type popularity, avg muted tickers
--
-- NOTE: This migration must be applied via Supabase MCP execute_sql on the BH project.
-- The full CREATE OR REPLACE FUNCTION is too large for a migration file.
-- Below is the SQL block to APPEND to the existing get_analytics_data() return JSON.

-- ============================================================
-- STEP 1: Add notification + telegram blocks to get_analytics_data()
-- ============================================================
-- Run this as a standalone block that adds keys to the existing JSON.
-- We use a wrapper approach: create a helper RPC that returns only notification data,
-- then the Edge Function calls both RPCs and merges.

CREATE OR REPLACE FUNCTION get_notification_analytics()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  result JSON;
BEGIN
  SELECT json_build_object(
    -- 1. Notifications by type (daily, last 90 days)
    'notifications_by_type_daily', (
      SELECT COALESCE(json_agg(row_to_json(r)), '[]'::json)
      FROM (
        SELECT
          alert_type,
          date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date AS day,
          COUNT(*) AS cnt
        FROM alert_notifications
        WHERE created_at >= now() - interval '90 days'
        GROUP BY alert_type, day
        ORDER BY day DESC, cnt DESC
      ) r
    ),

    -- 2. Notifications delivery overview (last 90 days)
    'notifications_delivery', (
      SELECT row_to_json(r)
      FROM (
        SELECT
          COUNT(*) AS total,
          COUNT(*) FILTER (WHERE read = true) AS read_count,
          COUNT(*) FILTER (WHERE telegram_delivered = true) AS telegram_delivered,
          COUNT(DISTINCT user_id) AS unique_users,
          COUNT(DISTINCT user_id) FILTER (WHERE read = true) AS users_who_read,
          ROUND(
            100.0 * COUNT(*) FILTER (WHERE read = true) / NULLIF(COUNT(*), 0), 1
          ) AS read_rate_pct,
          ROUND(
            100.0 * COUNT(*) FILTER (WHERE telegram_delivered = true) / NULLIF(COUNT(*), 0), 1
          ) AS telegram_rate_pct
        FROM alert_notifications
        WHERE created_at >= now() - interval '90 days'
      ) r
    ),

    -- 3. Notifications delivery daily (for time series)
    'notifications_delivery_daily', (
      SELECT COALESCE(json_agg(row_to_json(r)), '[]'::json)
      FROM (
        SELECT
          date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date AS day,
          COUNT(*) AS total,
          COUNT(*) FILTER (WHERE read = true) AS read_count,
          COUNT(*) FILTER (WHERE telegram_delivered = true) AS telegram_delivered
        FROM alert_notifications
        WHERE created_at >= now() - interval '90 days'
        GROUP BY day
        ORDER BY day DESC
      ) r
    ),

    -- 4. Top tickers by notification volume
    'notifications_top_tickers', (
      SELECT COALESCE(json_agg(row_to_json(r)), '[]'::json)
      FROM (
        SELECT
          ticker,
          COUNT(*) AS cnt,
          COUNT(DISTINCT alert_type) AS alert_types,
          COUNT(*) FILTER (WHERE read = true) AS read_count,
          COUNT(*) FILTER (WHERE telegram_delivered = true) AS telegram_delivered
        FROM alert_notifications
        WHERE created_at >= now() - interval '90 days'
          AND ticker IS NOT NULL
        GROUP BY ticker
        ORDER BY cnt DESC
        LIMIT 20
      ) r
    ),

    -- 5. Telegram overview (snapshot)
    'telegram_overview', (
      SELECT row_to_json(r)
      FROM (
        SELECT
          COUNT(*) AS total_links,
          COUNT(*) FILTER (WHERE active = true AND telegram_chat_id IS NOT NULL) AS active_links,
          COUNT(*) FILTER (WHERE active = false) AS inactive_links,
          COUNT(*) FILTER (WHERE active = true AND telegram_chat_id IS NULL) AS pending_links,
          COUNT(DISTINCT user_id) FILTER (WHERE active = true AND telegram_chat_id IS NOT NULL) AS linked_users
        FROM telegram_links
      ) r
    ),

    -- 6. Telegram links daily (new links over time)
    'telegram_links_daily', (
      SELECT COALESCE(json_agg(row_to_json(r)), '[]'::json)
      FROM (
        SELECT
          date_trunc('day', linked_at AT TIME ZONE 'America/Sao_Paulo')::date AS day,
          COUNT(*) AS new_links,
          COUNT(*) FILTER (WHERE active = true) AS active_links
        FROM telegram_links
        WHERE linked_at IS NOT NULL
          AND linked_at >= now() - interval '90 days'
        GROUP BY day
        ORDER BY day DESC
      ) r
    ),

    -- 7. Notification adoption funnel
    'notification_funnel', (
      SELECT row_to_json(r)
      FROM (
        SELECT
          (SELECT COUNT(*) FROM auth.users) AS total_users,
          (SELECT COUNT(DISTINCT user_id) FROM alert_notifications) AS users_with_notifications,
          (SELECT COUNT(DISTINCT user_id) FROM alert_notifications WHERE read = true) AS users_who_read,
          (SELECT COUNT(*) FROM notification_preferences WHERE enabled = true) AS users_with_prefs_enabled,
          (SELECT COUNT(DISTINCT user_id) FROM telegram_links WHERE active = true AND telegram_chat_id IS NOT NULL) AS users_with_telegram,
          (SELECT COUNT(DISTINCT user_id) FROM alert_notifications WHERE telegram_delivered = true) AS users_telegram_delivered
      ) r
    ),

    -- 8. Notification preferences summary
    'notification_prefs_summary', (
      SELECT row_to_json(r)
      FROM (
        SELECT
          COUNT(*) AS total_configured,
          COUNT(*) FILTER (WHERE enabled = true) AS enabled_count,
          ROUND(100.0 * COUNT(*) FILTER (WHERE enabled = true) / NULLIF(COUNT(*), 0), 1) AS enabled_pct,
          COUNT(*) FILTER (WHERE watch_portfolio = true) AS watch_portfolio_count,
          COUNT(*) FILTER (WHERE watch_teses = true) AS watch_teses_count,
          COUNT(*) FILTER (WHERE watch_analyses = true) AS watch_analyses_count,
          ROUND(AVG(COALESCE(array_length(muted_tickers, 1), 0)), 1) AS avg_muted_tickers
        FROM notification_preferences
      ) r
    ),

    -- 9. Notification type popularity (from preferences)
    'notification_type_popularity', (
      SELECT COALESCE(json_agg(row_to_json(r)), '[]'::json)
      FROM (
        SELECT
          t.type_name,
          COUNT(*) AS user_count
        FROM notification_preferences np,
             unnest(np.types) AS t(type_name)
        WHERE np.enabled = true
        GROUP BY t.type_name
        ORDER BY user_count DESC
      ) r
    )

  ) INTO result;

  RETURN result;
END;
$$;

-- Security: anon can call (Edge Function uses BH_ANON key).
-- Dashboard access is gated by admin JWT verification in the Edge Function itself.
-- Data returned is aggregated counts only (no PII).
GRANT EXECUTE ON FUNCTION get_notification_analytics() TO anon, authenticated;
