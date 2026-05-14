-- Airton Analytics RPC v2.3 — include_admins toggle (2026-05-14)
--
-- Adiciona 3o parametro `p_include_admins boolean DEFAULT false` em
-- get_analytics_data_airton_v2. Default mantem comportamento anterior (sem
-- admins, reflete realidade do produto). Quando true, relaxa o filtro nas
-- 4 CTEs que aplicavam exclusao via profiles.is_admin: `ev` (que lia de
-- usage_events_clean), `cm`, `ct` e `token_last_24h` (que tambem lia de
-- usage_events_clean).
--
-- Motivacao: enquanto AIrton ainda esta em early adoption, a maioria das
-- sessoes vem da equipe (gabriel/lucas/joao/lgt/qa-diag = 5 admins). Sem o
-- toggle, o dashboard parece "vazio" quando na verdade tem trafego interno
-- significativo. Toggle permite alternar entre visao oficial (real users)
-- e visao debug (incluindo admins) sem precisar duplicar a RPC.
--
-- CUIDADO PostgREST overload trap (feedback_postgrest_overload_trap): adicionar
-- 3o param com DEFAULT a uma RPC ja consumida com 2 args quebra chamadas
-- antigas via PostgREST com ERROR 42725 "function is not unique". Por isso a
-- sobrecarga antiga eh dropada explicitamente antes do CREATE OR REPLACE.

DROP FUNCTION IF EXISTS public.get_analytics_data_airton_v2(timestamptz, timestamptz);

CREATE OR REPLACE FUNCTION public.get_analytics_data_airton_v2(
  p_from timestamptz DEFAULT (now() - interval '30 days'),
  p_to   timestamptz DEFAULT now(),
  p_include_admins boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  WITH
  -- ─── Bases ───────────────────────────────────────────────────────────
  -- v2.3: deixa de consumir usage_events_clean diretamente e aplica filtro
  -- inline para poder honrar p_include_admins. Quando false (default), o
  -- comportamento eh identico a v2.1.
  ev AS (
    SELECT u.*
    FROM usage_events u
    WHERE event_ts BETWEEN p_from AND p_to
      AND (event_name LIKE 'companion%' OR event_name = 'gemini_token_usage')
      AND (
        p_include_admins
        OR NOT EXISTS (
          SELECT 1 FROM profiles p
          WHERE p.user_id = u.user_id AND p.is_admin = true
        )
      )
  ),
  cm AS (
    SELECT m.*
    FROM companion_messages m
    WHERE m.created_at BETWEEN p_from AND p_to
      AND (
        p_include_admins
        OR NOT EXISTS (
          SELECT 1 FROM profiles p
          WHERE p.user_id = m.user_id AND p.is_admin = true
        )
      )
  ),
  ct AS (
    SELECT t.*
    FROM companion_threads t
    WHERE (
      p_include_admins
      OR NOT EXISTS (
        SELECT 1 FROM profiles p
        WHERE p.user_id = t.user_id AND p.is_admin = true
      )
    )
  ),
  -- ─── Overview KPIs ───────────────────────────────────────────────────
  tokens_agg AS (
    SELECT
      COALESCE(SUM((properties->>'input_tokens')::bigint), 0)    AS input_tokens,
      COALESCE(SUM((properties->>'cached_tokens')::bigint), 0)   AS cached_tokens,
      COALESCE(SUM((properties->>'output_tokens')::bigint), 0)   AS output_tokens,
      COALESCE(SUM((properties->>'thoughts_tokens')::bigint), 0) AS thoughts_tokens,
      COALESCE(SUM((properties->>'total_tokens')::bigint), 0)    AS total_tokens,
      COUNT(*)                                                   AS requests_with_tokens
    FROM ev
    WHERE event_name = 'gemini_token_usage' AND action = 'companion'
  ),
  msg_agg AS (
    SELECT
      COUNT(*) FILTER (WHERE event_name = 'companion_message_sent' AND action = 'success') AS messages_success,
      COUNT(*) FILTER (WHERE event_name = 'companion_message_sent' AND action = 'error')   AS messages_error,
      COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'companion_message_sent')         AS unique_users,
      COUNT(*) FILTER (WHERE event_name = 'companion_opened')                              AS sessions_opened,
      COUNT(*) FILTER (WHERE event_name = 'companion_session_closed')                      AS sessions_closed,
      COUNT(*) FILTER (WHERE event_name = 'companion_first_user_message')                  AS first_messages,
      COUNT(*) FILTER (WHERE event_name IN ('companion_tool_call','companion_tool_called')) AS tool_calls
    FROM ev
  ),
  tg_agg AS (
    SELECT
      COUNT(DISTINCT user_id)                              AS tg_users,
      COUNT(*) FILTER (WHERE role = 'user')                AS tg_user_messages,
      COUNT(*) FILTER (WHERE role IN ('model','assistant')) AS tg_model_messages,
      COUNT(*)                                             AS tg_total_messages
    FROM cm
    WHERE source = 'telegram'
  ),
  overview AS (
    SELECT jsonb_build_object(
      'total_messages',      msg_agg.messages_success + msg_agg.messages_error,
      'messages_success',    msg_agg.messages_success,
      'messages_error',      msg_agg.messages_error,
      'error_rate',          CASE WHEN (msg_agg.messages_success + msg_agg.messages_error) > 0
                                  THEN ROUND(100.0 * msg_agg.messages_error / (msg_agg.messages_success + msg_agg.messages_error), 2)
                                  ELSE 0 END,
      'unique_users',        msg_agg.unique_users,
      'sessions_opened',     msg_agg.sessions_opened,
      'sessions_closed',     msg_agg.sessions_closed,
      'first_messages',      msg_agg.first_messages,
      'tool_calls',          msg_agg.tool_calls,
      'requests_with_tokens', tokens_agg.requests_with_tokens,
      'input_tokens',        tokens_agg.input_tokens,
      'cached_tokens',       tokens_agg.cached_tokens,
      'output_tokens',       tokens_agg.output_tokens,
      'thoughts_tokens',     tokens_agg.thoughts_tokens,
      'total_tokens',        tokens_agg.total_tokens,
      'telegram_users',      tg_agg.tg_users,
      'telegram_messages',   tg_agg.tg_total_messages,
      'telegram_share_pct',  CASE WHEN (msg_agg.messages_success + tg_agg.tg_user_messages) > 0
                                  THEN ROUND(100.0 * tg_agg.tg_user_messages / NULLIF(msg_agg.messages_success + tg_agg.tg_user_messages, 0), 2)
                                  ELSE 0 END
    ) AS data
    FROM msg_agg, tokens_agg, tg_agg
  ),
  -- ─── Daily activity ───────────────────────────────────────────────────
  daily AS (
    SELECT COALESCE(jsonb_agg(d ORDER BY d->>'day'), '[]'::jsonb) AS data
    FROM (
      SELECT jsonb_build_object(
        'day', to_char(date_trunc('day', event_ts), 'YYYY-MM-DD'),
        'messages_success', COUNT(*) FILTER (WHERE event_name = 'companion_message_sent' AND action = 'success'),
        'messages_error',   COUNT(*) FILTER (WHERE event_name = 'companion_message_sent' AND action = 'error'),
        'tool_calls',       COUNT(*) FILTER (WHERE event_name IN ('companion_tool_call','companion_tool_called')),
        'first_messages',   COUNT(*) FILTER (WHERE event_name = 'companion_first_user_message'),
        'sessions_opened',  COUNT(*) FILTER (WHERE event_name = 'companion_opened'),
        'unique_users',     COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'companion_message_sent')
      ) AS d
      FROM ev
      WHERE event_name IN ('companion_message_sent','companion_tool_call','companion_tool_called','companion_first_user_message','companion_opened')
      GROUP BY date_trunc('day', event_ts)
    ) sub
  ),
  -- ─── Funnel (unique users) ────────────────────────────────────────────
  funnel AS (
    SELECT jsonb_build_object(
      'opened',         COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'companion_opened'),
      'first_message',  COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'companion_first_user_message'),
      'tool_called',    COUNT(DISTINCT user_id) FILTER (WHERE event_name IN ('companion_tool_call','companion_tool_called')),
      'message_sent',   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'companion_message_sent' AND action = 'success'),
      'session_closed', COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'companion_session_closed'),
      'abandoned_at_greeting', COUNT(*) FILTER (WHERE event_name = 'companion_session_closed' AND (properties->>'abandoned_at_greeting')::boolean = true)
    ) AS data
    FROM ev
  ),
  -- ─── Tokens daily (por dia × model) ───────────────────────────────────
  token_daily AS (
    SELECT COALESCE(jsonb_agg(d ORDER BY d->>'day', d->>'model_used'), '[]'::jsonb) AS data
    FROM (
      SELECT jsonb_build_object(
        'day', to_char(date_trunc('day', event_ts), 'YYYY-MM-DD'),
        'model_used', COALESCE(properties->>'model_used','unknown'),
        'requests',        COUNT(*),
        'input_tokens',    COALESCE(SUM((properties->>'input_tokens')::bigint), 0),
        'cached_tokens',   COALESCE(SUM((properties->>'cached_tokens')::bigint), 0),
        'output_tokens',   COALESCE(SUM((properties->>'output_tokens')::bigint), 0),
        'thoughts_tokens', COALESCE(SUM((properties->>'thoughts_tokens')::bigint), 0),
        'total_tokens',    COALESCE(SUM((properties->>'total_tokens')::bigint), 0)
      ) AS d
      FROM ev
      WHERE event_name = 'gemini_token_usage' AND action = 'companion'
      GROUP BY date_trunc('day', event_ts), properties->>'model_used'
    ) sub
  ),
  -- ─── Tokens summary (por model) ───────────────────────────────────────
  token_summary AS (
    SELECT COALESCE(jsonb_agg(d ORDER BY (d->>'total_tokens')::bigint DESC), '[]'::jsonb) AS data
    FROM (
      SELECT jsonb_build_object(
        'model_used', COALESCE(properties->>'model_used','unknown'),
        'requests',        COUNT(*),
        'input_tokens',    COALESCE(SUM((properties->>'input_tokens')::bigint), 0),
        'cached_tokens',   COALESCE(SUM((properties->>'cached_tokens')::bigint), 0),
        'output_tokens',   COALESCE(SUM((properties->>'output_tokens')::bigint), 0),
        'thoughts_tokens', COALESCE(SUM((properties->>'thoughts_tokens')::bigint), 0),
        'total_tokens',    COALESCE(SUM((properties->>'total_tokens')::bigint), 0),
        'avg_total_per_request', ROUND(COALESCE(AVG((properties->>'total_tokens')::numeric), 0), 0)
      ) AS d
      FROM ev
      WHERE event_name = 'gemini_token_usage' AND action = 'companion'
      GROUP BY properties->>'model_used'
    ) sub
  ),
  -- ─── Tokens last 24h ──────────────────────────────────────────────────
  -- v2.3: tambem deixa de consumir usage_events_clean para honrar o param.
  token_last_24h AS (
    SELECT jsonb_build_object(
      'requests',        COUNT(*),
      'input_tokens',    COALESCE(SUM((properties->>'input_tokens')::bigint), 0),
      'cached_tokens',   COALESCE(SUM((properties->>'cached_tokens')::bigint), 0),
      'output_tokens',   COALESCE(SUM((properties->>'output_tokens')::bigint), 0),
      'thoughts_tokens', COALESCE(SUM((properties->>'thoughts_tokens')::bigint), 0),
      'total_tokens',    COALESCE(SUM((properties->>'total_tokens')::bigint), 0)
    ) AS data
    FROM usage_events u
    WHERE event_name = 'gemini_token_usage' AND action = 'companion'
      AND event_ts > now() - interval '24 hours'
      AND (
        p_include_admins
        OR NOT EXISTS (
          SELECT 1 FROM profiles p
          WHERE p.user_id = u.user_id AND p.is_admin = true
        )
      )
  ),
  -- ─── Context top (section/tab/ticker) ────────────────────────────────
  context_top AS (
    SELECT COALESCE(jsonb_agg(d ORDER BY (d->>'messages')::bigint DESC), '[]'::jsonb) AS data
    FROM (
      SELECT jsonb_build_object(
        'section', properties->>'section',
        'tab',     properties->>'tab',
        'ticker',  properties->>'ticker',
        'messages', COUNT(*),
        'unique_users', COUNT(DISTINCT user_id)
      ) AS d
      FROM ev
      WHERE event_name = 'companion_message_sent' AND action = 'success'
      GROUP BY properties->>'section', properties->>'tab', properties->>'ticker'
      ORDER BY COUNT(*) DESC
      LIMIT 30
    ) sub
  ),
  -- ─── Tool calls by tool_name ─────────────────────────────────────────
  tool_top AS (
    SELECT COALESCE(jsonb_agg(d ORDER BY (d->>'calls')::bigint DESC), '[]'::jsonb) AS data
    FROM (
      SELECT jsonb_build_object(
        'tool_name', COALESCE(properties->>'tool_name','(unknown)'),
        'calls',        COUNT(*),
        'success',      COUNT(*) FILTER (WHERE action = 'success'),
        'errors',       COUNT(*) FILTER (WHERE action = 'error'),
        'empty',        COUNT(*) FILTER (WHERE action = 'empty'),
        'unique_users', COUNT(DISTINCT user_id)
      ) AS d
      FROM ev
      WHERE event_name IN ('companion_tool_call','companion_tool_called')
      GROUP BY properties->>'tool_name'
      ORDER BY COUNT(*) DESC
      LIMIT 20
    ) sub
  ),
  tool_calls_daily AS (
    SELECT COALESCE(jsonb_agg(d ORDER BY d->>'day'), '[]'::jsonb) AS data
    FROM (
      SELECT jsonb_build_object(
        'day', to_char(date_trunc('day', event_ts), 'YYYY-MM-DD'),
        'calls',  COUNT(*),
        'success', COUNT(*) FILTER (WHERE action = 'success'),
        'errors',  COUNT(*) FILTER (WHERE action = 'error'),
        'empty',   COUNT(*) FILTER (WHERE action = 'empty')
      ) AS d
      FROM ev
      WHERE event_name IN ('companion_tool_call','companion_tool_called')
      GROUP BY date_trunc('day', event_ts)
    ) sub
  ),
  -- ─── Threads overview ─────────────────────────────────────────────────
  threads_overview AS (
    SELECT jsonb_build_object(
      'threads_created', (SELECT COUNT(*) FROM ct WHERE created_at BETWEEN p_from AND p_to),
      'threads_active',  (SELECT COUNT(DISTINCT thread_id) FROM cm),
      'avg_messages_per_thread', COALESCE((
        SELECT ROUND(AVG(msg_cnt), 1) FROM (
          SELECT thread_id, COUNT(*) AS msg_cnt FROM cm GROUP BY thread_id
        ) s
      ), 0),
      'threads_last_source_web',      (SELECT COUNT(*) FROM ct WHERE last_user_source = 'web' AND updated_at BETWEEN p_from AND p_to),
      'threads_last_source_telegram', (SELECT COUNT(*) FROM ct WHERE last_user_source = 'telegram' AND updated_at BETWEEN p_from AND p_to)
    ) AS data
  ),
  -- ─── Telegram overview ────────────────────────────────────────────────
  tg_users_by_channel AS (
    SELECT
      user_id,
      bool_or(source = 'telegram') AS has_tg,
      bool_or(source = 'web')      AS has_web
    FROM cm
    GROUP BY user_id
  ),
  telegram_overview AS (
    SELECT jsonb_build_object(
      'tg_unique_users',   (SELECT COUNT(DISTINCT user_id) FROM cm WHERE source = 'telegram'),
      'tg_user_messages',  (SELECT COUNT(*)                FROM cm WHERE source = 'telegram' AND role = 'user'),
      'tg_model_messages', (SELECT COUNT(*)                FROM cm WHERE source = 'telegram' AND role IN ('model','assistant')),
      'tg_total_messages', (SELECT COUNT(*)                FROM cm WHERE source = 'telegram'),
      'tg_threads_active', (SELECT COUNT(DISTINCT thread_id) FROM cm WHERE source = 'telegram'),
      'users_tg_only',     (SELECT COUNT(*) FROM tg_users_by_channel WHERE has_tg AND NOT has_web),
      'users_web_only',    (SELECT COUNT(*) FROM tg_users_by_channel WHERE has_web AND NOT has_tg),
      'users_web_and_tg',  (SELECT COUNT(*) FROM tg_users_by_channel WHERE has_tg AND has_web)
    ) AS data
  ),
  telegram_daily AS (
    SELECT COALESCE(jsonb_agg(d ORDER BY d->>'day'), '[]'::jsonb) AS data
    FROM (
      SELECT jsonb_build_object(
        'day', to_char(date_trunc('day', created_at), 'YYYY-MM-DD'),
        'user_messages',  COUNT(*) FILTER (WHERE role = 'user'),
        'model_messages', COUNT(*) FILTER (WHERE role IN ('model','assistant')),
        'total_messages', COUNT(*),
        'unique_users',   COUNT(DISTINCT user_id)
      ) AS d
      FROM cm
      WHERE source = 'telegram'
      GROUP BY date_trunc('day', created_at)
    ) sub
  ),
  telegram_cta_funnel AS (
    SELECT jsonb_build_object(
      'cta_clicked',    COUNT(*) FILTER (WHERE event_name = 'companion_telegram_cta_clicked'),
      'cta_dismissed',  COUNT(*) FILTER (WHERE event_name = 'companion_telegram_cta_dismissed'),
      'unique_clickers', COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'companion_telegram_cta_clicked')
    ) AS data
    FROM ev
    WHERE event_name IN ('companion_telegram_cta_clicked','companion_telegram_cta_dismissed')
  ),
  -- ─── Errors recent (daily) ────────────────────────────────────────────
  errors_recent AS (
    SELECT COALESCE(jsonb_agg(d ORDER BY d->>'day' DESC), '[]'::jsonb) AS data
    FROM (
      SELECT jsonb_build_object(
        'day', to_char(date_trunc('day', event_ts), 'YYYY-MM-DD'),
        'count', COUNT(*),
        'unique_users', COUNT(DISTINCT user_id),
        'top_error_code', COALESCE(
          (array_agg(error_code) FILTER (WHERE error_code IS NOT NULL))[1],
          '(none)'
        )
      ) AS d
      FROM ev
      WHERE event_name = 'companion_message_sent' AND action = 'error'
      GROUP BY date_trunc('day', event_ts)
    ) sub
  )

  SELECT jsonb_build_object(
    'airton_overview',         (SELECT data FROM overview),
    'airton_daily',            (SELECT data FROM daily),
    'airton_funnel',           (SELECT data FROM funnel),
    'airton_token_daily',      (SELECT data FROM token_daily),
    'airton_token_summary',    (SELECT data FROM token_summary),
    'airton_token_last_24h',   (SELECT data FROM token_last_24h),
    'airton_context_top',      (SELECT data FROM context_top),
    'airton_tool_top',         (SELECT data FROM tool_top),
    'airton_tool_calls_daily', (SELECT data FROM tool_calls_daily),
    'airton_threads_overview', (SELECT data FROM threads_overview),
    'airton_telegram_overview', (SELECT data FROM telegram_overview),
    'airton_telegram_daily',   (SELECT data FROM telegram_daily),
    'airton_telegram_cta_funnel', (SELECT data FROM telegram_cta_funnel),
    'airton_errors_recent',    (SELECT data FROM errors_recent),
    'meta', jsonb_build_object(
      'from', p_from,
      'to', p_to,
      'include_admins', p_include_admins,
      'admins_excluded_via', CASE WHEN p_include_admins THEN 'none' ELSE 'profiles.is_admin' END,
      'source', 'usage_events + companion_messages + companion_threads',
      'rpc_version', 'airton_v2.3_include_admins_toggle_20260514'
    )
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_analytics_data_airton_v2(timestamptz, timestamptz, boolean)
  TO anon, authenticated, service_role;

-- Reload PostgREST schema cache para garantir que /rpc/... pega a nova definicao
NOTIFY pgrst, 'reload schema';
