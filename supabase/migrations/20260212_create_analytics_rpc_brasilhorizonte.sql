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
        SELECT date_trunc('day', event_ts)::date as day,
               count(*) as events,
               count(DISTINCT user_id) as dau
        FROM public.usage_events
        GROUP BY day
        ORDER BY day DESC
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
    'conversion_funnel', (
      SELECT jsonb_build_object(
        'sessions', (SELECT count(*) FROM public.usage_events WHERE event_name = 'session_start'),
        'logins', (SELECT count(*) FROM public.usage_events WHERE event_name = 'login'),
        'paywall_blocks', (SELECT count(*) FROM public.usage_events WHERE event_name = 'paywall_block'),
        'checkout_starts', (SELECT count(*) FROM public.usage_events WHERE event_name = 'checkout_start'),
        'payments', (SELECT count(*) FROM public.usage_events WHERE event_name = 'payment_success'),
        'cancels', (SELECT count(*) FROM public.usage_events WHERE event_name = 'subscription_cancel')
      )
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
        SELECT date_trunc('day', created_at)::date as day,
               count(*) as downloads
        FROM public.report_downloads
        GROUP BY day
        ORDER BY day DESC
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
    )
  ) INTO result;

  RETURN result;
END;
$$;
