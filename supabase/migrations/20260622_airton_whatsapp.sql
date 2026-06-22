-- ============================================================================
-- Airton — WhatsApp channel parity (2026-06-22)
-- ----------------------------------------------------------------------------
-- WhatsApp substituiu o Telegram como canal ativo do Airton em 2026-06-10
-- (Telegram parou exatamente quando o WhatsApp comecou). companion_messages
-- agora recebe source='whatsapp' e ha um funil rico de eventos whatsapp_* em
-- usage_events. Esta migration:
--
--   1. Estende get_analytics_data_airton_v2 (v2.3) com blocos de mensagens
--      WhatsApp espelhando os blocos Telegram (CTE cm ja respeita o toggle
--      p_include_admins). Assinatura NAO muda -> Edge Function intacta.
--   2. Cria a RPC complementar get_analytics_data_airton_whatsapp_v1, espelho
--      de get_analytics_data_airton_telegram_v1, lendo de usage_events_clean
--      (admins ja excluidos) para funil de vinculacao + offers + features +
--      outcomes + sinal de migracao TG->WA.
--
-- Notas de schema (verificadas no DB dawvgbopyemcayavcatd em 2026-06-22):
--   - companion_messages.role usa 'user' / 'model' (igual ao Telegram).
--   - whatsapp_token_generated tem success = NULL (NAO filtrar por success,
--     diferente do telegram_token_generated que usava success=true).
--   - whatsapp_message_received usa coluna booleana success + properties.outcome
--     ('success' / 'empty_response').
--   - whatsapp_gemini_latency_ms guarda a latencia em properties.ms.
--   - WhatsApp nao tem command_used / start_received (usa briefing/cvm como
--     features). O funil de vinculacao comeca em whatsapp_offer_shown.
-- ============================================================================

-- Overload-trap guard: DROP a assinatura exata antes do CREATE OR REPLACE
DROP FUNCTION IF EXISTS public.get_analytics_data_airton_v2(timestamptz, timestamptz, boolean);

CREATE OR REPLACE FUNCTION public.get_analytics_data_airton_v2(
  p_from timestamptz DEFAULT (now() - '30 days'::interval),
  p_to timestamptz DEFAULT now(),
  p_include_admins boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  WITH
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
  wa_agg AS (
    SELECT
      COUNT(DISTINCT user_id)                              AS wa_users,
      COUNT(*) FILTER (WHERE role = 'user')                AS wa_user_messages,
      COUNT(*) FILTER (WHERE role IN ('model','assistant')) AS wa_model_messages,
      COUNT(*)                                             AS wa_total_messages
    FROM cm
    WHERE source = 'whatsapp'
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
                                  ELSE 0 END,
      'whatsapp_users',      wa_agg.wa_users,
      'whatsapp_messages',   wa_agg.wa_total_messages,
      'whatsapp_share_pct',  CASE WHEN (msg_agg.messages_success + wa_agg.wa_user_messages) > 0
                                  THEN ROUND(100.0 * wa_agg.wa_user_messages / NULLIF(msg_agg.messages_success + wa_agg.wa_user_messages, 0), 2)
                                  ELSE 0 END
    ) AS data
    FROM msg_agg, tokens_agg, tg_agg, wa_agg
  ),
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
      'threads_last_source_telegram', (SELECT COUNT(*) FROM ct WHERE last_user_source = 'telegram' AND updated_at BETWEEN p_from AND p_to),
      'threads_last_source_whatsapp', (SELECT COUNT(*) FROM ct WHERE last_user_source = 'whatsapp' AND updated_at BETWEEN p_from AND p_to)
    ) AS data
  ),
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
  wa_users_by_channel AS (
    SELECT
      user_id,
      bool_or(source = 'whatsapp') AS has_wa,
      bool_or(source = 'web')      AS has_web
    FROM cm
    GROUP BY user_id
  ),
  whatsapp_overview AS (
    SELECT jsonb_build_object(
      'wa_unique_users',   (SELECT COUNT(DISTINCT user_id) FROM cm WHERE source = 'whatsapp'),
      'wa_user_messages',  (SELECT COUNT(*)                FROM cm WHERE source = 'whatsapp' AND role = 'user'),
      'wa_model_messages', (SELECT COUNT(*)                FROM cm WHERE source = 'whatsapp' AND role IN ('model','assistant')),
      'wa_total_messages', (SELECT COUNT(*)                FROM cm WHERE source = 'whatsapp'),
      'wa_threads_active', (SELECT COUNT(DISTINCT thread_id) FROM cm WHERE source = 'whatsapp'),
      'users_wa_only',     (SELECT COUNT(*) FROM wa_users_by_channel WHERE has_wa AND NOT has_web),
      'users_web_only',    (SELECT COUNT(*) FROM wa_users_by_channel WHERE has_web AND NOT has_wa),
      'users_web_and_wa',  (SELECT COUNT(*) FROM wa_users_by_channel WHERE has_wa AND has_web)
    ) AS data
  ),
  whatsapp_daily AS (
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
      WHERE source = 'whatsapp'
      GROUP BY date_trunc('day', created_at)
    ) sub
  ),
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
    'airton_whatsapp_overview', (SELECT data FROM whatsapp_overview),
    'airton_whatsapp_daily',   (SELECT data FROM whatsapp_daily),
    'airton_errors_recent',    (SELECT data FROM errors_recent),
    'meta', jsonb_build_object(
      'from', p_from,
      'to', p_to,
      'include_admins', p_include_admins,
      'admins_excluded_via', CASE WHEN p_include_admins THEN 'none' ELSE 'profiles.is_admin' END,
      'source', 'usage_events + companion_messages + companion_threads',
      'rpc_version', 'airton_v2.4_whatsapp_20260622'
    )
  )
  INTO v_result;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_analytics_data_airton_v2(timestamptz, timestamptz, boolean)
  TO authenticated, service_role;


-- ============================================================================
-- RPC complementar: funil de vinculacao + offers + features + outcomes WhatsApp
-- Espelho de get_analytics_data_airton_telegram_v1. Le de usage_events_clean
-- (admins ja excluidos pela view; sem toggle p_include_admins, igual ao TG).
-- ============================================================================
DROP FUNCTION IF EXISTS public.get_analytics_data_airton_whatsapp_v1(timestamptz, timestamptz);

CREATE OR REPLACE FUNCTION public.get_analytics_data_airton_whatsapp_v1(
  p_from timestamptz DEFAULT (now() - '30 days'::interval),
  p_to timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  WITH
  ev AS (
    SELECT *
    FROM usage_events_clean
    WHERE event_ts BETWEEN p_from AND p_to
      AND (
        event_name LIKE 'whatsapp_%'
        OR event_name IN ('home_whatsmoved_viewed','telegram_whatsapp_invite_sent')
      )
  ),
  -- Funil de vinculacao (usuarios unicos por etapa).
  -- NB: whatsapp_token_generated tem success=NULL -> NAO filtrar por success.
  linking_funnel AS (
    SELECT jsonb_build_object(
      'offer_shown',      COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_offer_shown'),
      'connect_clicked',  COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_connect_clicked'),
      'token_generated',  COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_token_generated'),
      'token_copied',     COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_token_copied'),
      'bot_link_clicked', COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_bot_link_clicked'),
      'link_received',    COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_link_received'),
      'verify_clicked',   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_verify_clicked'),
      'linked',           COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_linked'),
      'unlinked',         COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_unlinked'),
      'optout',           COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_optout')
    ) AS data
    FROM ev
  ),
  offers AS (
    SELECT jsonb_build_object(
      'offer_shown',          COUNT(*) FILTER (WHERE event_name = 'whatsapp_offer_shown'),
      'offer_clicked',        COUNT(*) FILTER (WHERE event_name = 'whatsapp_offer_clicked'),
      'offer_dismissed',      COUNT(*) FILTER (WHERE event_name = 'whatsapp_offer_dismissed'),
      'offer_token_refreshed', COUNT(*) FILTER (WHERE event_name = 'whatsapp_offer_token_refreshed'),
      'unique_shown',         COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_offer_shown'),
      'unique_clickers',      COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_offer_clicked')
    ) AS data
    FROM ev
  ),
  funnel_daily AS (
    SELECT COALESCE(jsonb_agg(d ORDER BY d->>'day'), '[]'::jsonb) AS data
    FROM (
      SELECT jsonb_build_object(
        'day', to_char(date_trunc('day', event_ts), 'YYYY-MM-DD'),
        'offer_shown',     COUNT(*) FILTER (WHERE event_name = 'whatsapp_offer_shown'),
        'connect_clicked', COUNT(*) FILTER (WHERE event_name = 'whatsapp_connect_clicked'),
        'token_generated', COUNT(*) FILTER (WHERE event_name = 'whatsapp_token_generated'),
        'linked',          COUNT(*) FILTER (WHERE event_name = 'whatsapp_linked'),
        'unlinked',        COUNT(*) FILTER (WHERE event_name = 'whatsapp_unlinked')
      ) AS d
      FROM ev
      WHERE event_name IN (
        'whatsapp_offer_shown', 'whatsapp_connect_clicked',
        'whatsapp_token_generated', 'whatsapp_linked', 'whatsapp_unlinked'
      )
      GROUP BY date_trunc('day', event_ts)
    ) sub
  ),
  features AS (
    SELECT jsonb_build_object(
      'briefing_request',    COUNT(*) FILTER (WHERE event_name = 'whatsapp_briefing_request'),
      'briefing_delivered',  COUNT(*) FILTER (WHERE event_name = 'whatsapp_briefing_delivered'),
      'briefing_users',      COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_briefing_request'),
      'cvm_pdf_request',     COUNT(*) FILTER (WHERE event_name = 'whatsapp_cvm_pdf_request'),
      'cvm_open_request',    COUNT(*) FILTER (WHERE event_name = 'whatsapp_cvm_open_request'),
      'cvm_users',           COUNT(DISTINCT user_id) FILTER (WHERE event_name IN ('whatsapp_cvm_pdf_request','whatsapp_cvm_open_request'))
    ) AS data
    FROM ev
  ),
  message_outcomes AS (
    SELECT jsonb_build_object(
      'success',           COUNT(*) FILTER (WHERE event_name = 'whatsapp_message_received' AND properties->>'outcome' = 'success'),
      'empty_response',    COUNT(*) FILTER (WHERE event_name = 'whatsapp_message_received' AND properties->>'outcome' = 'empty_response'),
      'failed',            COUNT(*) FILTER (WHERE event_name = 'whatsapp_message_received' AND success IS FALSE),
      'total',             COUNT(*) FILTER (WHERE event_name = 'whatsapp_message_received'),
      'unique_users',      COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'whatsapp_message_received'),
      'avg_latency_ms',    ROUND(COALESCE(AVG((properties->>'ms')::numeric) FILTER (WHERE event_name = 'whatsapp_gemini_latency_ms'), 0), 0),
      'fallback_recovery_shown', COUNT(*) FILTER (WHERE event_name = 'whatsapp_fallback_recovery_shown'),
      'thread_reset',      COUNT(*) FILTER (WHERE event_name = 'whatsapp_thread_reset')
    ) AS data
    FROM ev
  ),
  migration AS (
    SELECT jsonb_build_object(
      'whatsmoved_viewed',       COUNT(*) FILTER (WHERE event_name = 'home_whatsmoved_viewed'),
      'whatsmoved_unique_users', COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'home_whatsmoved_viewed'),
      'tg_invite_sent',          COUNT(*) FILTER (WHERE event_name = 'telegram_whatsapp_invite_sent'),
      'tg_invite_unique_users',  COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'telegram_whatsapp_invite_sent')
    ) AS data
    FROM ev
  )
  SELECT jsonb_build_object(
    'airton_whatsapp_linking_funnel',   (SELECT data FROM linking_funnel),
    'airton_whatsapp_offers',           (SELECT data FROM offers),
    'airton_whatsapp_funnel_daily',     (SELECT data FROM funnel_daily),
    'airton_whatsapp_features',         (SELECT data FROM features),
    'airton_whatsapp_message_outcomes', (SELECT data FROM message_outcomes),
    'airton_whatsapp_migration',        (SELECT data FROM migration),
    'meta', jsonb_build_object(
      'from', p_from,
      'to', p_to,
      'rpc_version', 'airton_whatsapp_v1',
      'source', 'usage_events_clean'
    )
  )
  INTO v_result;
  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_analytics_data_airton_whatsapp_v1(timestamptz, timestamptz)
  TO authenticated, service_role;

-- Recarrega o schema cache do PostgREST
NOTIFY pgrst, 'reload schema';
