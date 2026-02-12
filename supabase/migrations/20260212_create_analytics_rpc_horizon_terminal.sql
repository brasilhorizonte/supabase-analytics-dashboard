-- Migration: create analytics RPC for Horizon Terminal Access (llqhmywodxzstjlrulcw)
-- Apply this to the Horizon Terminal Access project

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
    'terminal_events_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT feature, action,
               count(*) as event_count,
               avg(duration_ms) as avg_duration_ms
        FROM public.terminal_events
        GROUP BY feature, action
        ORDER BY event_count DESC
        LIMIT 20
      ) t
    ),
    'terminal_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', created_at)::date as day,
               count(DISTINCT session_id) as sessions,
               count(*) FILTER (WHERE feature = 'agent') as tasks,
               count(*) FILTER (WHERE feature = 'chat') as chat_msgs
        FROM public.terminal_events
        WHERE created_at > now() - interval '14 days'
        GROUP BY day
        ORDER BY day DESC
      ) t
    ),
    'chat_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', m.created_at)::date as day,
               count(*) as messages,
               count(DISTINCT s.user_id) as unique_users
        FROM public.chat_messages m
        JOIN public.chat_sessions s ON s.id = m.session_id
        WHERE m.created_at > now() - interval '14 days'
        GROUP BY day
        ORDER BY day DESC
      ) t
    ),
    'daily_usage', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT usage_date as day,
               sum(request_count) as requests
        FROM public.proxy_daily_usage
        WHERE usage_date > (now() - interval '14 days')::date
        GROUP BY usage_date
        ORDER BY usage_date DESC
      ) t
    ),
    'watchlist', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT ticker, count(*) as users
        FROM public.user_watchlist
        GROUP BY ticker
        ORDER BY users DESC
        LIMIT 15
      ) t
    ),
    'user_profiles_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT status, client_type, count(*) as cnt
        FROM public.user_profiles
        GROUP BY status, client_type
        ORDER BY cnt DESC
      ) t
    ),
    'documents_by_type', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT doc_type, count(*) as total
        FROM public.documents
        GROUP BY doc_type
        ORDER BY total DESC
      ) t
    ),
    'login_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', login_at)::date as day,
               count(*) as logins,
               count(DISTINCT user_id) as unique_users
        FROM public.user_login_events
        WHERE login_at > now() - interval '14 days'
        GROUP BY day
        ORDER BY day DESC
      ) t
    ),
    'top_tickers_searched', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT ticker, count(*) as cnt
        FROM public.terminal_events
        WHERE ticker IS NOT NULL AND ticker != ''
        GROUP BY ticker ORDER BY cnt DESC LIMIT 15
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
    )
  ) INTO result;

  RETURN result;
END;
$$;
