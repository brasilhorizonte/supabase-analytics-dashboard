-- Migration: Enhance token analytics in get_analytics_data() for HTA
-- Apply to: Horizon Terminal Access (llqhmywodxzstjlrulcw)
-- Adds: token_stats, token_by_mode, top_queries_by_token
-- Updates: token_usage_daily, token_usage_summary, token_usage_by_user to prefer real tokens via COALESCE

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
        'sessions', (SELECT count(DISTINCT session_id) FROM public.terminal_events WHERE created_at >= now() - interval '24 hours'),
        'tasks', (SELECT count(*) FROM public.terminal_events WHERE feature = 'agent' AND created_at >= now() - interval '24 hours'),
        'chat_msgs', (SELECT count(*) FROM public.terminal_events WHERE feature = 'chat' AND created_at >= now() - interval '24 hours'),
        'logins', (SELECT count(*) FROM public.user_login_events WHERE login_at >= now() - interval '24 hours'),
        'unique_users', (SELECT count(DISTINCT user_id) FROM public.terminal_events WHERE created_at >= now() - interval '24 hours'),
        'chat_messages', (SELECT count(*) FROM public.chat_messages WHERE created_at >= now() - interval '24 hours'),
        'requests', (SELECT coalesce(sum(request_count), 0) FROM public.proxy_daily_usage WHERE usage_date >= (now() AT TIME ZONE 'America/Sao_Paulo')::date),
        'input_tokens', (SELECT coalesce(sum(input_tokens), 0) FROM public.proxy_daily_usage WHERE usage_date >= (now() AT TIME ZONE 'America/Sao_Paulo')::date),
        'output_tokens', (SELECT coalesce(sum(output_tokens), 0) FROM public.proxy_daily_usage WHERE usage_date >= (now() AT TIME ZONE 'America/Sao_Paulo')::date)
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
        SELECT date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               count(DISTINCT session_id) as sessions,
               count(*) FILTER (WHERE feature = 'agent') as tasks,
               count(*) FILTER (WHERE feature = 'chat') as chat_msgs
        FROM public.terminal_events
        GROUP BY day
        ORDER BY day ASC
      ) t
    ),
    'chat_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', m.created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               count(*) as messages,
               count(DISTINCT s.user_id) as unique_users
        FROM public.chat_messages m
        JOIN public.chat_sessions s ON s.id = m.session_id
        GROUP BY day
        ORDER BY day ASC
      ) t
    ),
    'daily_usage', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT usage_date as day,
               sum(request_count) as requests
        FROM public.proxy_daily_usage
        GROUP BY usage_date
        ORDER BY usage_date ASC
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
        SELECT date_trunc('day', login_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               count(*) as logins,
               count(DISTINCT user_id) as unique_users
        FROM public.user_login_events
        GROUP BY day
        ORDER BY day ASC
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
    ),
    -- Token usage daily: prefer real tokens (total_prompt_tokens/total_completion_tokens) over estimates
    'token_usage_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT usage_date as day, proxy_name,
          SUM(request_count) as requests,
          SUM(COALESCE(NULLIF(total_prompt_tokens, 0), input_tokens)) as input_tokens,
          SUM(COALESCE(NULLIF(total_completion_tokens, 0), output_tokens)) as output_tokens,
          bool_or(estimated) as has_estimates
        FROM public.proxy_daily_usage
        GROUP BY usage_date, proxy_name
        ORDER BY usage_date ASC
      ) t
    ),
    -- Token usage summary: prefer real tokens
    'token_usage_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT proxy_name,
          SUM(request_count) as total_requests,
          SUM(COALESCE(NULLIF(total_prompt_tokens, 0), input_tokens)) as total_input_tokens,
          SUM(COALESCE(NULLIF(total_completion_tokens, 0), output_tokens)) as total_output_tokens,
          COUNT(DISTINCT user_id) as unique_users
        FROM public.proxy_daily_usage
        GROUP BY proxy_name
      ) t
    ),
    -- Token usage by user: prefer real tokens
    'token_usage_by_user', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT p.user_id, coalesce(u.email, p.user_id::text) as email,
          p.proxy_name,
          SUM(p.request_count) as total_requests,
          SUM(COALESCE(NULLIF(p.total_prompt_tokens, 0), p.input_tokens)) as total_input_tokens,
          SUM(COALESCE(NULLIF(p.total_completion_tokens, 0), p.output_tokens)) as total_output_tokens
        FROM public.proxy_daily_usage p
        LEFT JOIN auth.users u ON u.id = p.user_id
        GROUP BY p.user_id, u.email, p.proxy_name
        ORDER BY SUM(COALESCE(NULLIF(p.total_prompt_tokens, 0), p.input_tokens)) + SUM(COALESCE(NULLIF(p.total_completion_tokens, 0), p.output_tokens)) DESC
      ) t
    ),
    -- NEW: Token stats from terminal_events (agent answer_done)
    'token_stats', (
      SELECT row_to_json(t) FROM (
        SELECT
          COUNT(*) as total_queries,
          COUNT(token_count) as queries_with_tokens,
          COALESCE(SUM(token_count), 0) as total_tokens,
          COALESCE(AVG(token_count)::int, 0) as avg_tokens_per_query
        FROM public.terminal_events
        WHERE event_name = 'terminal_agent_answer_done'
      ) t
    ),
    -- NEW: Token breakdown by response mode (Deep vs Fast)
    'token_by_mode', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          COALESCE(response_mode, 'unknown') as mode,
          COUNT(*) as query_count,
          COALESCE(SUM(token_count), 0) as total_tokens,
          COALESCE(AVG(token_count)::int, 0) as avg_tokens
        FROM public.terminal_events
        WHERE event_name = 'terminal_agent_answer_done'
        GROUP BY response_mode
      ) t
    ),
    -- NEW: Top 20 queries by token count
    'top_queries_by_token', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          event_ts, user_id, ticker, response_mode,
          duration_ms, token_count,
          (properties->>'prompt_tokens')::int as prompt_tokens,
          (properties->>'completion_tokens')::int as completion_tokens,
          (properties->>'call_count')::int as call_count
        FROM public.terminal_events
        WHERE event_name = 'terminal_agent_answer_done'
          AND token_count IS NOT NULL
        ORDER BY token_count DESC
        LIMIT 20
      ) t
    ),
    'device_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT device_type, count(*) as cnt, count(DISTINCT user_id) as unique_users
        FROM public.terminal_events
        WHERE device_type IS NOT NULL
        GROUP BY device_type
        ORDER BY cnt DESC
      ) t
    ),
    'device_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               device_type,
               count(*) as cnt,
               count(DISTINCT user_id) as unique_users
        FROM public.terminal_events
        WHERE device_type IS NOT NULL
        GROUP BY day, device_type
        ORDER BY day ASC
      ) t
    ),
    'os_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT os, count(*) as cnt
        FROM public.terminal_events
        WHERE os IS NOT NULL
        GROUP BY os
        ORDER BY cnt DESC
      ) t
    ),
    'browser_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT browser, count(*) as cnt
        FROM public.terminal_events
        WHERE browser IS NOT NULL
        GROUP BY browser
        ORDER BY cnt DESC
      ) t
    ),
    'agent_success_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               count(*) FILTER (WHERE action = 'task_start') as started,
               count(*) FILTER (WHERE action = 'task_end') as completed,
               count(*) FILTER (WHERE action = 'answer_done') as answered,
               count(*) FILTER (WHERE action IN ('task_error', 'workflow_error', 'aborted')) as failed,
               round(
                 count(*) FILTER (WHERE action = 'task_end')::numeric /
                 nullif(count(*) FILTER (WHERE action = 'task_start'), 0) * 100, 1
               ) as success_rate
        FROM public.terminal_events
        WHERE feature = 'agent'
        GROUP BY day
        ORDER BY day ASC
      ) t
    ),
    'agent_duration_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               round((avg(duration_ms) / 1000)::numeric, 1) as avg_duration_sec,
               round((percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms) / 1000)::numeric, 1) as median_duration_sec,
               round((max(duration_ms) / 1000)::numeric, 1) as max_duration_sec,
               count(*) as tasks
        FROM public.terminal_events
        WHERE feature = 'agent' AND action = 'answer_done'
          AND duration_ms IS NOT NULL AND duration_ms > 0
        GROUP BY day
        ORDER BY day ASC
      ) t
    ),
    'response_mode_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT response_mode, count(*) as cnt,
               count(DISTINCT user_id) as unique_users
        FROM public.terminal_events
        WHERE response_mode IS NOT NULL
        GROUP BY response_mode
        ORDER BY cnt DESC
      ) t
    ),
    'response_mode_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               response_mode,
               count(*) as cnt
        FROM public.terminal_events
        WHERE response_mode IS NOT NULL
        GROUP BY day, response_mode
        ORDER BY day ASC
      ) t
    ),
    'chat_depth_distribution', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH session_msg_count AS (
          SELECT session_id, count(*) as msgs
          FROM public.chat_messages
          GROUP BY session_id
        )
        SELECT
          CASE
            WHEN msgs <= 2 THEN '1-2 msgs'
            WHEN msgs <= 4 THEN '3-4 msgs'
            WHEN msgs <= 6 THEN '5-6 msgs'
            WHEN msgs <= 8 THEN '7-8 msgs'
            ELSE '9+ msgs'
          END as bucket,
          count(*) as sessions,
          round(avg(msgs)::numeric, 1) as avg_msgs
        FROM session_msg_count
        GROUP BY bucket
        ORDER BY min(msgs)
      ) t
    ),
    'questions_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT usage_date as day,
               sum(question_count) as total_questions,
               count(DISTINCT user_id) as active_users,
               round(avg(question_count)::numeric, 1) as avg_per_user
        FROM public.user_daily_usage
        GROUP BY usage_date
        ORDER BY usage_date ASC
      ) t
    )
  ) INTO result;

  RETURN result;
END;
$$;
