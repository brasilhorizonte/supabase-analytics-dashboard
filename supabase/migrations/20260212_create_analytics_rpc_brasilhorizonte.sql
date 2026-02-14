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
    )
  ) INTO result;

  RETURN result;
END;
$$;
