-- Airton Telegram Funnel + Friction Signals (2026-05-13)
--
-- RPC complementar à get_analytics_data_airton_v2 (não substitui). Foca em:
--   1. Funnel de linking web (section_viewed → connect_clicked → token_generated
--      → token_copied / bot_link_clicked → linked)
--   2. Outcomes do /start <token> no bot (success / invalid_format /
--      token_not_found / expired / chat_conflict)
--   3. Comandos usados no Telegram (/limpar, /briefing, /sair, /ajuda, etc)
--   4. Friction signals (rate limit hits + tool limit exhausted) — sinais
--      diretos pra upgrade campaign por trigger comportamental
--   5. Sources do section_viewed (campaign attribution: direct vs post_checkout
--      vs campaign UTM)
--
-- Eventos consumidos (todos novos, instrumentados em 2026-05-13):
--   Frontend (IntegrationsNotificationsApp): telegram_section_viewed,
--     telegram_connect_clicked, telegram_token_generated, telegram_token_copied,
--     telegram_bot_link_clicked, telegram_linked_realtime, telegram_linked_manual,
--     telegram_verify_clicked, telegram_unlinked, telegram_phone_*
--   Receiver server-side: telegram_start_received, telegram_command_used,
--     telegram_message_received, telegram_sair_outcome, telegram_rate_limited,
--     telegram_linked, telegram_unlinked
--   Gemini-ai server-side: companion_rate_limited, companion_tool_limit_exhausted

CREATE OR REPLACE FUNCTION public.get_analytics_data_airton_telegram_v1(
  p_from timestamptz DEFAULT (now() - interval '30 days'),
  p_to   timestamptz DEFAULT now()
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
  -- Base: usage_events_clean já exclui admins via filter (instrumentado em
  -- 20260503_bh_engagement_v2_admin_filter.sql). Janela temporal aplicada.
  ev AS (
    SELECT *
    FROM usage_events_clean
    WHERE event_ts BETWEEN p_from AND p_to
      AND (
        event_name LIKE 'telegram_%'
        OR event_name IN ('companion_rate_limited', 'companion_tool_limit_exhausted')
      )
  ),
  -- ─── Linking Funnel ─────────────────────────────────────────────────
  -- Usuários únicos em cada etapa. "linked_any" combina os 3 paths (realtime,
  -- manual via botão Verificar, server-side via /start). Cada user aparece
  -- 1x mesmo se linkar várias vezes (UNION via OR no FILTER).
  linking_funnel AS (
    SELECT jsonb_build_object(
      'section_viewed',   COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'telegram_section_viewed'),
      'connect_clicked',  COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'telegram_connect_clicked'),
      'token_generated',  COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'telegram_token_generated' AND success = true),
      'token_copied',     COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'telegram_token_copied'),
      'bot_link_clicked', COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'telegram_bot_link_clicked'),
      'linked_realtime',  COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'telegram_linked_realtime'),
      'linked_manual',    COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'telegram_linked_manual'),
      'linked_server',    COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'telegram_linked'),
      'linked_any',       COUNT(DISTINCT user_id) FILTER (WHERE event_name IN (
        'telegram_linked_realtime', 'telegram_linked_manual', 'telegram_linked'
      )),
      'unlinked',         COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'telegram_unlinked')
    ) AS data
    FROM ev
  ),
  -- ─── /start <token> Outcomes ────────────────────────────────────────
  -- Pivot pelas outcomes (success / invalid_format / token_not_found /
  -- expired / chat_conflict). Sinal de qualidade do flow ponta-a-ponta.
  start_outcomes AS (
    SELECT jsonb_build_object(
      'outcomes', COALESCE(jsonb_agg(d ORDER BY (d->>'count')::bigint DESC NULLS LAST), '[]'::jsonb)
    ) AS data
    FROM (
      SELECT jsonb_build_object(
        'outcome',      COALESCE(properties->>'outcome', '(unknown)'),
        'count',        COUNT(*),
        'unique_users', COUNT(DISTINCT user_id)
      ) AS d
      FROM ev
      WHERE event_name = 'telegram_start_received'
      GROUP BY properties->>'outcome'
    ) sub
  ),
  -- ─── Commands ─────────────────────────────────────────────────────────
  -- Comandos /xxx usados no Telegram (capturados no receiver antes do
  -- Gemini call). Útil pra entender engagement com features estruturadas
  -- (/briefing on-demand, /limpar pra nova conversa, /sair churn etc).
  commands AS (
    SELECT jsonb_build_object(
      'commands', COALESCE(jsonb_agg(d ORDER BY (d->>'count')::bigint DESC NULLS LAST), '[]'::jsonb)
    ) AS data
    FROM (
      SELECT jsonb_build_object(
        'cmd',          COALESCE(properties->>'cmd', '(unknown)'),
        'count',        COUNT(*),
        'unique_users', COUNT(DISTINCT user_id)
      ) AS d
      FROM ev
      WHERE event_name = 'telegram_command_used'
      GROUP BY properties->>'cmd'
    ) sub
  ),
  -- ─── Friction Signals ────────────────────────────────────────────────
  -- Rate limit hits (2 layers: receiver 100/h universal, gemini-ai 10/h
  -- free | 100/h premium). Tool limit exhausted (free 30 lifetime, sinal
  -- forte de upgrade). Trigger de campaign comportamental.
  friction AS (
    SELECT jsonb_build_object(
      'rate_limited_receiver_hits', COUNT(*) FILTER (WHERE event_name = 'telegram_rate_limited'),
      'rate_limited_gemini_hits',   COUNT(*) FILTER (WHERE event_name = 'companion_rate_limited'),
      'rate_limited_unique_users',  COUNT(DISTINCT user_id) FILTER (WHERE event_name IN ('telegram_rate_limited', 'companion_rate_limited')),
      'rate_limited_free_users',    COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'companion_rate_limited' AND properties->>'tier' = 'free'),
      'rate_limited_telegram_source', COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'companion_rate_limited' AND properties->>'source' = 'telegram'),
      'tool_limit_exhausted_hits',  COUNT(*) FILTER (WHERE event_name = 'companion_tool_limit_exhausted'),
      'tool_limit_exhausted_users', COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'companion_tool_limit_exhausted'),
      'tool_limit_telegram_users',  COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'companion_tool_limit_exhausted' AND properties->>'source' = 'telegram'),
      'tool_limit_web_users',       COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'companion_tool_limit_exhausted' AND properties->>'source' = 'web')
    ) AS data
    FROM ev
  ),
  -- ─── Section Sources (attribution) ───────────────────────────────────
  -- Source mix do section_viewed: direct vs post_checkout (Stripe) vs
  -- campaign (utm_source presente). Importante pra medir blast de email.
  section_sources AS (
    SELECT jsonb_build_object(
      'sources', COALESCE(jsonb_agg(d ORDER BY (d->>'count')::bigint DESC), '[]'::jsonb)
    ) AS data
    FROM (
      SELECT jsonb_build_object(
        'source',       COALESCE(properties->>'source', '(unknown)'),
        'utm_source',   properties->>'utm_source',
        'count',        COUNT(*),
        'unique_users', COUNT(DISTINCT user_id)
      ) AS d
      FROM ev
      WHERE event_name = 'telegram_section_viewed'
      GROUP BY properties->>'source', properties->>'utm_source'
    ) sub
  ),
  -- ─── Daily Funnel Series ─────────────────────────────────────────────
  -- Série diária dos principais marcos (section_viewed, connect, token,
  -- linked, unlinked). Permite ver impacto de campanhas no tempo.
  funnel_daily AS (
    SELECT COALESCE(jsonb_agg(d ORDER BY d->>'day'), '[]'::jsonb) AS data
    FROM (
      SELECT jsonb_build_object(
        'day', to_char(date_trunc('day', event_ts), 'YYYY-MM-DD'),
        'section_viewed',  COUNT(*) FILTER (WHERE event_name = 'telegram_section_viewed'),
        'connect_clicked', COUNT(*) FILTER (WHERE event_name = 'telegram_connect_clicked'),
        'token_generated', COUNT(*) FILTER (WHERE event_name = 'telegram_token_generated' AND success = true),
        'linked_any',      COUNT(*) FILTER (WHERE event_name IN ('telegram_linked_realtime', 'telegram_linked_manual', 'telegram_linked')),
        'unlinked',        COUNT(*) FILTER (WHERE event_name = 'telegram_unlinked')
      ) AS d
      FROM ev
      WHERE event_name IN (
        'telegram_section_viewed', 'telegram_connect_clicked',
        'telegram_token_generated', 'telegram_linked_realtime',
        'telegram_linked_manual', 'telegram_linked', 'telegram_unlinked'
      )
      GROUP BY date_trunc('day', event_ts)
    ) sub
  ),
  -- ─── Message Outcomes (server-side via receiver) ─────────────────────
  -- Sucesso/erro de mensagens processadas pelo receiver. Complementa
  -- companion_message_sent do frontend com a perspectiva do bot Telegram.
  message_outcomes AS (
    SELECT jsonb_build_object(
      'success',          COUNT(*) FILTER (WHERE event_name = 'telegram_message_received' AND success = true),
      'gemini_error',     COUNT(*) FILTER (WHERE event_name = 'telegram_message_received' AND properties->>'outcome' = 'gemini_error'),
      'empty_response',   COUNT(*) FILTER (WHERE event_name = 'telegram_message_received' AND properties->>'outcome' = 'empty_response'),
      'exception',        COUNT(*) FILTER (WHERE event_name = 'telegram_message_received' AND properties->>'outcome' = 'exception'),
      'with_media',       COUNT(*) FILTER (WHERE event_name = 'telegram_message_received' AND (properties->>'has_media')::boolean = true),
      'unique_users',     COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'telegram_message_received')
    ) AS data
    FROM ev
  )

  SELECT jsonb_build_object(
    'airton_telegram_linking_funnel',  (SELECT data FROM linking_funnel),
    'airton_telegram_start_outcomes',  (SELECT data FROM start_outcomes),
    'airton_telegram_commands',        (SELECT data FROM commands),
    'airton_telegram_friction',        (SELECT data FROM friction),
    'airton_telegram_section_sources', (SELECT data FROM section_sources),
    'airton_telegram_funnel_daily',    (SELECT data FROM funnel_daily),
    'airton_telegram_message_outcomes', (SELECT data FROM message_outcomes),
    'meta', jsonb_build_object(
      'from', p_from,
      'to', p_to,
      'rpc_version', 'airton_telegram_v1',
      'source', 'usage_events_clean'
    )
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_analytics_data_airton_telegram_v1(timestamptz, timestamptz)
  TO anon, authenticated, service_role;
