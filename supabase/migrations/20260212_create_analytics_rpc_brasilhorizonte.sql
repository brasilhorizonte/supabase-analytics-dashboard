-- Migration: create analytics RPC for brasilhorizonte (dawvgbopyemcayavcatd)
-- Apply this to the brasilhorizonte project

CREATE OR REPLACE FUNCTION public.get_analytics_data()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'overview', (
      SELECT jsonb_build_object(
        'total_users', (SELECT count(*) FROM auth.users),
        'active_sessions', (SELECT count(*) FROM auth.sessions WHERE not_after > now()),
        'storage_objects', (SELECT count(*) FROM storage.objects),
        'db_size_bytes', (SELECT pg_database_size(current_database()))
      )
    ),
    'last_24h', (
      SELECT jsonb_build_object(
        'events', (SELECT count(*) FROM public.usage_events WHERE event_ts >= now() - interval '24 hours'),
        'dau', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_ts >= now() - interval '24 hours'),
        'signups', (SELECT count(*) FROM public.profiles WHERE created_at >= now() - interval '24 hours'),
        'logins', (SELECT count(*) FROM public.usage_events WHERE event_name = 'login' AND event_ts >= now() - interval '24 hours'),
        'paywall_blocks', (SELECT count(*) FROM public.usage_events WHERE event_name = 'paywall_block' AND event_ts >= now() - interval '24 hours'),
        'payments', (SELECT count(*) FROM public.usage_events WHERE event_name = 'payment_succeeded' AND event_ts >= now() - interval '24 hours'),
        'cancels', (SELECT count(*) FROM public.usage_events WHERE event_name = 'subscription_cancel' AND event_ts >= now() - interval '24 hours'),
        'report_downloads', (SELECT count(*) FROM public.report_downloads WHERE created_at >= now() - interval '24 hours')
      )
    ),
    'usage_events_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT event_name, count(*) as cnt
        FROM public.usage_events
        GROUP BY event_name
        ORDER BY cnt DESC
        LIMIT 15
      ) t
    ),
    'daily_activity', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               count(*) as events,
               count(DISTINCT user_id) as dau
        FROM public.usage_events
        GROUP BY day
        ORDER BY day ASC
      ) t
    ),
    'feature_usage', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT feature, count(*) as cnt
        FROM public.usage_events
        WHERE feature IS NOT NULL
        GROUP BY feature
        ORDER BY cnt DESC
        LIMIT 10
      ) t
    ),
    'feature_usage_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               feature,
               count(*) as cnt
        FROM public.usage_events
        WHERE feature IS NOT NULL
        GROUP BY day, feature
        ORDER BY day ASC
      ) t
    ),
    'conversion_funnel', (
      SELECT jsonb_build_object(
        'sessions', (SELECT count(*) FROM public.usage_events WHERE event_name = 'session_start'),
        'logins', (SELECT count(*) FROM public.usage_events WHERE event_name = 'login'),
        'paywall_blocks', (SELECT count(*) FROM public.usage_events WHERE event_name = 'paywall_block'),
        'checkout_starts', (SELECT count(*) FROM public.usage_events WHERE event_name = 'checkout_start'),
        'payments', (SELECT count(*) FROM public.usage_events WHERE event_name = 'payment_succeeded'),
        'cancels', (SELECT count(*) FROM public.usage_events WHERE event_name = 'subscription_cancel')
      )
    ),
    'device_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT device_type, count(*) as cnt, count(DISTINCT user_id) as unique_users
        FROM public.usage_events
        WHERE device_type IS NOT NULL
        GROUP BY device_type
        ORDER BY cnt DESC
      ) t
    ),
    'device_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               device_type,
               count(*) as cnt,
               count(DISTINCT user_id) as unique_users
        FROM public.usage_events
        WHERE device_type IS NOT NULL
        GROUP BY day, device_type
        ORDER BY day ASC
      ) t
    ),
    'os_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT os, count(*) as cnt
        FROM public.usage_events
        WHERE os IS NOT NULL
        GROUP BY os
        ORDER BY cnt DESC
      ) t
    ),
    'browser_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT browser, count(*) as cnt
        FROM public.usage_events
        WHERE browser IS NOT NULL
        GROUP BY browser
        ORDER BY cnt DESC
      ) t
    ),
    'top_tickers_market', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT ticker, sector, regular_market_price as price,
               market_cap, regular_market_volume,
               regular_market_change_percent, dividend_yield, pl
        FROM public.brapi_quotes
        WHERE market_cap IS NOT NULL
        ORDER BY market_cap DESC NULLS LAST
        LIMIT 20
      ) t
    ),
    'sector_distribution', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT sector, count(*) as tickers
        FROM public.brapi_quotes
        WHERE sector IS NOT NULL AND sector != ''
        GROUP BY sector
        ORDER BY tickers DESC
      ) t
    ),
    'table_sizes', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT relname as name,
               n_live_tup as rows,
               pg_total_relation_size(relid) as size_bytes
        FROM pg_stat_user_tables
        WHERE schemaname = 'public'
        ORDER BY n_live_tup DESC
        LIMIT 20
      ) t
    ),
    'report_downloads_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               count(*) as downloads
        FROM public.report_downloads
        GROUP BY day
        ORDER BY day ASC
      ) t
    ),
    'top_tickers_searched', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT ticker, count(*) as cnt
        FROM public.usage_events
        WHERE ticker IS NOT NULL AND ticker != ''
        GROUP BY ticker ORDER BY cnt DESC LIMIT 15
      ) t
    ),
    'subscribers_overview', (
      SELECT jsonb_build_object(
        'total_profiles', (SELECT count(*) FROM public.profiles),
        'active', (SELECT count(*) FROM public.profiles WHERE subscription_status = 'active'),
        'inactive', (SELECT count(*) FROM public.profiles WHERE subscription_status = 'inactive'),
        'free', (SELECT count(*) FROM public.profiles WHERE subscription_status IS NULL OR subscription_status = 'free'),
        'special_clients', (SELECT count(*) FROM public.profiles WHERE is_special_client = true),
        'churn_rate', (
          SELECT round(
            (SELECT count(*)::numeric FROM public.usage_events WHERE event_name = 'subscription_cancel')
            / nullif(
              (SELECT count(*) FROM public.profiles WHERE subscription_status = 'active')
              + (SELECT count(*) FROM public.usage_events WHERE event_name = 'subscription_cancel'),
              0
            ) * 100, 1
          )
        )
      )
    ),
    'subscribers_by_plan', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT coalesce(plan, 'free') as plan,
               coalesce(subscription_status, 'free') as status,
               billing_period,
               count(*) as cnt
        FROM public.profiles
        GROUP BY plan, subscription_status, billing_period
        ORDER BY cnt DESC
      ) t
    ),
    'signups_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date as day, count(*) as signups
        FROM public.profiles
        GROUP BY day
        ORDER BY day ASC
      ) t
    ),
    'subscription_events_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
          count(*) FILTER (WHERE event_name = 'paywall_block') as paywall_blocks,
          count(*) FILTER (WHERE event_name = 'checkout_start') as checkout_starts,
          count(*) FILTER (WHERE event_name = 'checkout_complete') as checkout_completes,
          count(*) FILTER (WHERE event_name = 'payment_succeeded') as payments,
          count(*) FILTER (WHERE event_name = 'subscription_cancel') as cancels
        FROM public.usage_events
        WHERE event_name IN ('paywall_block', 'checkout_start', 'checkout_complete', 'payment_succeeded', 'subscription_cancel')
        GROUP BY day
        ORDER BY day ASC
      ) t
    ),
    'retention_cohorts', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT to_char(p.created_at AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') as cohort,
          count(DISTINCT p.user_id) as cohort_size,
          count(DISTINCT CASE WHEN ue.event_ts >= p.created_at + interval '7 days' THEN p.user_id END) as retained_7d,
          count(DISTINCT CASE WHEN ue.event_ts >= p.created_at + interval '30 days' THEN p.user_id END) as retained_30d,
          count(DISTINCT CASE WHEN ue.event_ts >= p.created_at + interval '60 days' THEN p.user_id END) as retained_60d,
          count(DISTINCT CASE WHEN ue.event_ts >= p.created_at + interval '90 days' THEN p.user_id END) as retained_90d
        FROM public.profiles p
        LEFT JOIN public.usage_events ue ON ue.user_id = p.user_id
        GROUP BY cohort
        ORDER BY cohort ASC
      ) t
    ),
    'top_routes', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT route as page_path, count(*) as views,
               count(DISTINCT user_id) as unique_users,
               count(DISTINCT session_id) as sessions
        FROM public.usage_events
        WHERE route IS NOT NULL
        GROUP BY route
        ORDER BY views DESC
        LIMIT 10
      ) t
    ),
    'top_landing_pages', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT split_part(landing_page, '?', 1) as landing,
               count(*) as entries,
               count(DISTINCT user_id) as unique_users
        FROM public.usage_events
        WHERE landing_page IS NOT NULL AND event_name = 'session_start'
        GROUP BY landing
        ORDER BY entries DESC
        LIMIT 10
      ) t
    ),
    'referrer_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT CASE
                 WHEN referrer IS NULL OR referrer = '' THEN 'Direto'
                 WHEN referrer LIKE '%stripe.com%' THEN 'Stripe Checkout'
                 WHEN referrer LIKE '%lovable%' THEN 'Lovable (Dev)'
                 WHEN referrer LIKE '%brasilhorizonte%' THEN 'App BH (interno)'
                 WHEN referrer LIKE '%localhost%' THEN 'Localhost (Dev)'
                 WHEN referrer LIKE '%google%' THEN 'Google'
                 ELSE split_part(replace(replace(referrer, 'https://', ''), 'http://', ''), '/', 1)
               END as source,
               count(*) as visits,
               count(DISTINCT user_id) as unique_users
        FROM public.usage_events
        GROUP BY source
        ORDER BY visits DESC
        LIMIT 10
      ) t
    ),
    'screen_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT screen, count(*) as cnt
        FROM public.usage_events
        WHERE screen IS NOT NULL
        GROUP BY screen
        ORDER BY cnt DESC
        LIMIT 10
      ) t
    ),
    'session_metrics_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH session_stats AS (
          SELECT session_id,
                 date_trunc('day', min(event_ts) AT TIME ZONE 'America/Sao_Paulo')::date as day,
                 count(*) as events,
                 extract(epoch FROM max(event_ts) - min(event_ts)) as duration_secs
          FROM public.usage_events
          WHERE session_id IS NOT NULL
          GROUP BY session_id
          HAVING count(*) > 1
        )
        SELECT day,
               round(avg(events)::numeric, 1) as avg_events_per_session,
               round((avg(duration_secs) / 60)::numeric, 1) as avg_duration_min,
               round((percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_secs) / 60)::numeric, 1) as median_duration_min,
               count(*) as total_sessions
        FROM session_stats
        GROUP BY day
        ORDER BY day ASC
      ) t
    ),
    'stickiness', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH user_days AS (
          SELECT DISTINCT
            date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
            user_id
          FROM public.usage_events
          WHERE user_id IS NOT NULL
        ),
        daily_counts AS (
          SELECT day, count(*) as dau FROM user_days GROUP BY day
        ),
        weekly_counts AS (
          SELECT d.day, count(DISTINCT ud.user_id) as wau
          FROM (SELECT DISTINCT day FROM user_days) d
          JOIN user_days ud ON ud.day BETWEEN d.day - 6 AND d.day
          GROUP BY d.day
        ),
        monthly_counts AS (
          SELECT d.day, count(DISTINCT ud.user_id) as mau
          FROM (SELECT DISTINCT day FROM user_days) d
          JOIN user_days ud ON ud.day BETWEEN d.day - 29 AND d.day
          GROUP BY d.day
        )
        SELECT dc.day, dc.dau, wc.wau, mc.mau,
               round(dc.dau::numeric / nullif(wc.wau, 0) * 100, 1) as dau_wau_pct,
               round(dc.dau::numeric / nullif(mc.mau, 0) * 100, 1) as dau_mau_pct
        FROM daily_counts dc
        JOIN weekly_counts wc ON wc.day = dc.day
        JOIN monthly_counts mc ON mc.day = dc.day
        ORDER BY dc.day ASC
      ) t
    ),
    'new_vs_returning_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH user_first_day AS (
          SELECT user_id,
                 min(date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date) as first_day
          FROM public.usage_events
          WHERE user_id IS NOT NULL
          GROUP BY user_id
        ),
        daily_users AS (
          SELECT DISTINCT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
                 user_id
          FROM public.usage_events
          WHERE user_id IS NOT NULL
        )
        SELECT du.day,
               count(*) FILTER (WHERE du.day = uf.first_day) as new_users,
               count(*) FILTER (WHERE du.day > uf.first_day) as returning_users
        FROM daily_users du
        JOIN user_first_day uf ON uf.user_id = du.user_id
        GROUP BY du.day
        ORDER BY du.day ASC
      ) t
    ),
    'activity_heatmap', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT extract(dow FROM event_ts AT TIME ZONE 'America/Sao_Paulo')::int as dow,
               extract(hour FROM event_ts AT TIME ZONE 'America/Sao_Paulo')::int as hour,
               count(*) as events
        FROM public.usage_events
        GROUP BY dow, hour
        ORDER BY dow, hour
      ) t
    ),
    'time_to_convert', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH first_payment AS (
          SELECT user_id, min(event_ts) as paid_at
          FROM public.usage_events
          WHERE event_name = 'payment_succeeded'
          GROUP BY user_id
        )
        SELECT
          CASE
            WHEN extract(epoch FROM fp.paid_at - p.created_at) / 86400 <= 1 THEN '< 1 dia'
            WHEN extract(epoch FROM fp.paid_at - p.created_at) / 86400 <= 3 THEN '1-3 dias'
            WHEN extract(epoch FROM fp.paid_at - p.created_at) / 86400 <= 7 THEN '3-7 dias'
            WHEN extract(epoch FROM fp.paid_at - p.created_at) / 86400 <= 14 THEN '7-14 dias'
            WHEN extract(epoch FROM fp.paid_at - p.created_at) / 86400 <= 30 THEN '14-30 dias'
            ELSE '30+ dias'
          END as bucket,
          count(*) as conversions,
          round(avg(extract(epoch FROM fp.paid_at - p.created_at) / 86400)::numeric, 1) as avg_days
        FROM first_payment fp
        JOIN public.profiles p ON p.user_id = fp.user_id
        GROUP BY bucket
        ORDER BY min(extract(epoch FROM fp.paid_at - p.created_at))
      ) t
    ),
    'feature_paywall', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT feature, count(*) as paywall_hits
        FROM public.usage_events
        WHERE session_id IN (
          SELECT DISTINCT session_id FROM public.usage_events
          WHERE event_name = 'paywall_block' AND session_id IS NOT NULL
        )
        AND feature IS NOT NULL AND event_name = 'feature_open'
        GROUP BY feature
        ORDER BY paywall_hits DESC
        LIMIT 10
      ) t
    ),
    'mrr_estimate', (
      SELECT jsonb_build_object(
        'monthly_subs', (SELECT count(*) FROM public.profiles WHERE subscription_status = 'active' AND billing_period = 'monthly'),
        'yearly_subs', (SELECT count(*) FROM public.profiles WHERE subscription_status = 'active' AND billing_period = 'yearly'),
        'lifetime_subs', (SELECT count(*) FROM public.profiles WHERE subscription_status = 'active' AND billing_period = 'lifetime'),
        'total_payments', (SELECT count(*) FROM public.usage_events WHERE event_name = 'payment_succeeded'),
        'total_paying_users', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'payment_succeeded'),
        'avg_subscription_age_days', (
          SELECT round(avg(extract(epoch FROM now() - created_at) / 86400)::numeric, 0)
          FROM public.profiles WHERE subscription_status = 'active'
        )
      )
    ),
    'subscription_age', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          CASE
            WHEN extract(epoch FROM now() - created_at) / 86400 <= 7 THEN '< 1 sem'
            WHEN extract(epoch FROM now() - created_at) / 86400 <= 30 THEN '1-4 sem'
            WHEN extract(epoch FROM now() - created_at) / 86400 <= 90 THEN '1-3 meses'
            WHEN extract(epoch FROM now() - created_at) / 86400 <= 180 THEN '3-6 meses'
            ELSE '6+ meses'
          END as age_bucket,
          count(*) as users,
          count(*) FILTER (WHERE subscription_status = 'active') as active,
          count(*) FILTER (WHERE subscription_status != 'active' OR subscription_status IS NULL) as churned
        FROM public.profiles
        WHERE created_at IS NOT NULL
        GROUP BY age_bucket
        ORDER BY min(extract(epoch FROM now() - created_at))
      ) t
    ),
    'section_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               section,
               count(*) as cnt
        FROM public.usage_events
        WHERE section IS NOT NULL
        GROUP BY day, section
        ORDER BY day ASC
      ) t
    )
  ) INTO result;

  RETURN result;
END;
$$;
