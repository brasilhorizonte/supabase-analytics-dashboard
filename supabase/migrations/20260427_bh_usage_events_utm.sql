-- Migration: BH usage_events UTM analytics
-- Date: 2026-04-27
-- Adds a new dedicated RPC (get_analytics_data_bh_utm) that aggregates UTM
-- attribution from public.usage_events. Designed to power the "Campanhas UTM"
-- section of the analytics dashboard for Brasil Horizonte (app.brasilhorizonte.com.br).
-- Project: brasilhorizonte (dawvgbopyemcayavcatd)
--
-- Why a NEW function instead of extending get_analytics_data_bh_extras():
--   - Zero risk of regressing the existing function under load.
--   - Cleaner separation of concerns; rollback is a single DROP FUNCTION.
--   - The dashboard edge function already merges multiple RPCs via spread —
--     no refactor needed there beyond adding one fetchRpc() call.
--
-- Window:
--   Most aggregations are limited to the last 90 days to keep the RPC fast
--   as usage_events grows. The 50OFF campaign block uses its own date window
--   (2026-04-27 to 2026-05-03) and is independent of the 90-day filter.

CREATE OR REPLACE FUNCTION public.get_analytics_data_bh_utm()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  window_start timestamptz := now() - interval '90 days';
  promo_start  timestamptz := '2026-04-27 00:00:00-03'::timestamptz;
  promo_end    timestamptz := '2026-05-03 23:59:59-03'::timestamptz;
BEGIN
  result := jsonb_build_object(

    -- ===== Top sources/mediums/campaigns (last 90d) =====
    'usage_utm_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          coalesce(utm_source, '(none)')   AS utm_source,
          coalesce(utm_medium, '(none)')   AS utm_medium,
          coalesce(utm_campaign, '(none)') AS utm_campaign,
          count(*)                                                                       AS events,
          count(DISTINCT session_id)                                                     AS sessions,
          count(DISTINCT user_id) FILTER (WHERE user_id IS NOT NULL)                     AS unique_users,
          count(*) FILTER (WHERE event_name = 'auth_login')                              AS logins,
          count(*) FILTER (WHERE event_name LIKE 'paywall%' OR event_name = 'paywall_block') AS paywall_events,
          count(*) FILTER (WHERE event_name = 'payment_succeeded')                       AS payments
        FROM public.usage_events
        WHERE event_ts >= window_start
          AND (utm_source IS NOT NULL OR utm_medium IS NOT NULL OR utm_campaign IS NOT NULL)
        GROUP BY 1, 2, 3
        ORDER BY events DESC
        LIMIT 30
      ) t
    ),

    -- ===== Daily series by source (last 90d) — for stacked bar chart =====
    'usage_utm_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
          coalesce(utm_source, '(none)') AS utm_source,
          count(*)                       AS events,
          count(DISTINCT session_id)     AS sessions
        FROM public.usage_events
        WHERE event_ts >= window_start
          AND utm_source IS NOT NULL
        GROUP BY 1, 2
        ORDER BY 1 ASC
      ) t
    ),

    -- ===== Breakdown by utm_content (creative-level performance) =====
    -- Naming convention used by the campaign: {feature}_{channel}_{format}
    -- e.g. valuai_yt_video, score_ig_reel, radar_tw_thread
    'usage_utm_by_content', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          utm_content,
          coalesce(utm_source, '(none)')   AS utm_source,
          coalesce(utm_medium, '(none)')   AS utm_medium,
          coalesce(utm_campaign, '(none)') AS utm_campaign,
          count(*)                                                       AS events,
          count(DISTINCT session_id)                                     AS sessions,
          count(DISTINCT user_id) FILTER (WHERE user_id IS NOT NULL)     AS unique_users,
          count(*) FILTER (WHERE event_name = 'auth_login')              AS logins,
          count(*) FILTER (WHERE event_name = 'payment_succeeded')       AS payments
        FROM public.usage_events
        WHERE event_ts >= window_start
          AND utm_content IS NOT NULL
        GROUP BY 1, 2, 3, 4
        ORDER BY events DESC
        LIMIT 50
      ) t
    ),

    -- ===== Conversion funnel by source (session-level join) =====
    -- Maps utm_source -> %sessions that reached login/paywall/payment.
    -- This is the chart that answers "which channel converts best?".
    'usage_utm_funnel_by_source', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH attributed_sessions AS (
          SELECT DISTINCT session_id, user_id, coalesce(utm_source, '(none)') AS utm_source
          FROM public.usage_events
          WHERE event_ts >= window_start
            AND utm_source IS NOT NULL
            AND session_id IS NOT NULL
        )
        SELECT
          a.utm_source,
          count(DISTINCT a.session_id) AS sessions,
          count(DISTINCT a.session_id) FILTER (
            WHERE EXISTS (
              SELECT 1 FROM public.usage_events e
              WHERE e.session_id = a.session_id AND e.event_name = 'auth_login'
            )
          ) AS sessions_with_login,
          count(DISTINCT a.session_id) FILTER (
            WHERE EXISTS (
              SELECT 1 FROM public.usage_events e
              WHERE e.session_id = a.session_id
                AND (e.event_name LIKE 'paywall%' OR e.event_name = 'paywall_block')
            )
          ) AS sessions_with_paywall,
          count(DISTINCT a.session_id) FILTER (
            WHERE EXISTS (
              SELECT 1 FROM public.usage_events e
              WHERE e.session_id = a.session_id AND e.event_name = 'payment_succeeded'
            )
          ) AS sessions_with_payment
        FROM attributed_sessions a
        GROUP BY a.utm_source
        HAVING count(DISTINCT a.session_id) >= 3
        ORDER BY sessions DESC
        LIMIT 20
      ) t
    ),

    -- ===== Campaign 50OFF specific snapshot (Apr 2026) =====
    -- Hard-coded date window because the campaign has a defined start/end.
    -- Replace or add new blocks for future campaigns.
    'usage_utm_50off_summary', (
      SELECT jsonb_build_object(
        'campaign_id',          '50off_apr2026',
        'window_start',         promo_start,
        'window_end',           promo_end,
        'events',               (SELECT count(*) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end),
        'sessions',             (SELECT count(DISTINCT session_id) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end),
        'unique_users',         (SELECT count(DISTINCT user_id) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end
                                    AND user_id IS NOT NULL),
        'logins',               (SELECT count(*) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end
                                    AND event_name = 'auth_login'),
        'signups',              (SELECT count(DISTINCT user_id) FROM public.usage_events
                                  WHERE session_id IN (
                                    SELECT DISTINCT session_id FROM public.usage_events
                                    WHERE utm_campaign = '50off_apr2026'
                                      AND event_ts BETWEEN promo_start AND promo_end
                                  )
                                  AND event_name = 'auth_signup'),
        'paywall_views',        (SELECT count(*) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end
                                    AND (event_name LIKE 'paywall%' OR event_name = 'paywall_block')),
        'checkout_starts',      (SELECT count(*) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end
                                    AND event_name IN ('checkout_started','credit_exhausted_checkout_start')),
        'payments',             (SELECT count(*) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end
                                    AND event_name = 'payment_succeeded')
      )
    ),

    -- Daily breakdown for the 50OFF campaign — used for time-series chart
    'usage_utm_50off_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
          coalesce(utm_source, '(none)') AS utm_source,
          count(*)                                                       AS events,
          count(DISTINCT session_id)                                     AS sessions,
          count(*) FILTER (WHERE event_name = 'payment_succeeded')       AS payments
        FROM public.usage_events
        WHERE utm_campaign = '50off_apr2026'
          AND event_ts BETWEEN promo_start AND promo_end
        GROUP BY 1, 2
        ORDER BY 1 ASC
      ) t
    ),

    -- 50OFF campaign — top creatives (utm_content)
    -- Answers "which video/reel/thread drove the most conversions?".
    'usage_utm_50off_top_content', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          utm_content,
          coalesce(utm_source, '(none)') AS utm_source,
          coalesce(utm_medium, '(none)') AS utm_medium,
          count(*)                                                  AS events,
          count(DISTINCT session_id)                                AS sessions,
          count(*) FILTER (WHERE event_name = 'auth_login')         AS logins,
          count(*) FILTER (WHERE event_name = 'payment_succeeded')  AS payments
        FROM public.usage_events
        WHERE utm_campaign = '50off_apr2026'
          AND event_ts BETWEEN promo_start AND promo_end
          AND utm_content IS NOT NULL
        GROUP BY 1, 2, 3
        ORDER BY events DESC
        LIMIT 30
      ) t
    )
  );

  RETURN result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_analytics_data_bh_utm() TO anon, authenticated, service_role;

-- Notify PostgREST to reload its schema cache
NOTIFY pgrst, 'reload schema';
