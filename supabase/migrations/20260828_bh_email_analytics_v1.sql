-- =====================================================================
-- Email Analytics v1 (2026-08-28) -- projeto brasilhorizonte (BH)
--
-- Motivacao: a aba "Detalhes" mostrava email como 2 graficos crus
-- (email_type x total). Com 37 email_types distintos e sem nenhuma
-- taxonomia, a secao era ilegivel e nao respondia nada sobre performance.
--
-- Esta migration adiciona:
--   1. Taxonomia canonica de emails em 3 eixos (categoria / cadencia / estagio)
--      via 3 funcoes IMMUTABLE reutilizaveis.
--   2. RPC get_analytics_data_bh_email_v1(p_from, p_to, p_include_admins)
--      com 16 secoes, incluindo funil de clique atribuido por UTM.
--
-- IMPORTANTE -- "taxa de abertura" NAO existe hoje:
--   email_log nao tem opened_at/clicked_at e nao ha webhook do provedor
--   (nenhuma edge function recebe eventos de entrega). O proxy honesto de
--   engajamento e o CLIQUE, reconstruido via utm_source='email' em
--   usage_events. Ver secao "click attribution" abaixo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Taxonomia
-- ---------------------------------------------------------------------

-- Categoria: familia funcional do email.
CREATE OR REPLACE FUNCTION public.bh_email_category(p_type text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE
    WHEN p_type IN ('daily_cvm_digest','weekly_cvm_digest')                      THEN 'digest'
    WHEN p_type LIKE 'welcome%'
      OR p_type = 'subscription_welcome'
      OR p_type LIKE 'unconfirmed_activation%'                                   THEN 'onboarding'
    WHEN p_type LIKE 'trial_ending%' OR p_type LIKE 'trial_ended%'               THEN 'trial'
    WHEN p_type LIKE 'dunning%'                                                  THEN 'dunning'
    WHEN p_type LIKE '%catchback%' OR p_type LIKE 'getback%'                     THEN 'winback'
    WHEN p_type LIKE 'portfolio_activation%'                                     THEN 'activation'
    WHEN p_type LIKE 'community_%'                                               THEN 'community'
    WHEN p_type = 'content_notification'                                         THEN 'content'
    WHEN p_type LIKE 'broadcast%' OR p_type LIKE '%announcement%'
      OR p_type LIKE 'platform_update%' OR p_type LIKE 'instagram%'              THEN 'announcement'
    WHEN p_type = 'manual'                                                       THEN 'manual'
    ELSE 'other'
  END
$fn$;

-- Cadencia: COMO o email e disparado.
--   recorrente = agendado periodicamente (digests)
--   automatico = disparado por evento/gatilho do ciclo de vida do usuario
--   campanha   = blast pontual decidido pelo time
--   manual     = envio avulso
CREATE OR REPLACE FUNCTION public.bh_email_cadence(p_type text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE public.bh_email_category(p_type)
    WHEN 'digest'       THEN 'recorrente'
    WHEN 'onboarding'   THEN 'automatico'
    WHEN 'trial'        THEN 'automatico'
    WHEN 'dunning'      THEN 'automatico'
    WHEN 'winback'      THEN 'automatico'
    WHEN 'activation'   THEN 'automatico'
    WHEN 'content'      THEN 'automatico'
    WHEN 'community'    THEN 'campanha'
    WHEN 'announcement' THEN 'campanha'
    WHEN 'manual'       THEN 'manual'
    ELSE 'other'
  END
$fn$;

-- Estagio: ONDE no funil o email atua.
CREATE OR REPLACE FUNCTION public.bh_email_stage(p_type text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE public.bh_email_category(p_type)
    WHEN 'onboarding'   THEN 'ativacao'
    WHEN 'activation'   THEN 'ativacao'
    WHEN 'digest'       THEN 'engajamento'
    WHEN 'content'      THEN 'engajamento'
    WHEN 'community'    THEN 'engajamento'
    WHEN 'announcement' THEN 'engajamento'
    WHEN 'winback'      THEN 'retencao'
    WHEN 'trial'        THEN 'monetizacao'
    WHEN 'dunning'      THEN 'monetizacao'
    ELSE 'outro'
  END
$fn$;

GRANT EXECUTE ON FUNCTION public.bh_email_category(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.bh_email_cadence(text)  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.bh_email_stage(text)    TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. RPC principal
-- ---------------------------------------------------------------------
-- Click attribution:
--   usage_events guarda utm_* de forma STICKY (a UTM da sessao/usuario e
--   reemitida em todo evento seguinte -- ex: weekly_cvm_digest_2026W19 tem
--   9.134 eventos para 7 usuarios, ao longo de 3 meses). Portanto contar
--   eventos superestima grosseiramente. Aqui o clique e sempre o
--   FIRST-TOUCH por (usuario, campanha), e so conta se ocorreu DEPOIS do
--   envio e dentro de 30 dias.
--   A chave de match sao os 3 valores metadata->>'utm_campaign',
--   metadata->>'campaign' e email_type (juntos cobrem 17/17 das
--   utm_campaign de email observadas em usage_events).
DROP FUNCTION IF EXISTS public.get_analytics_data_bh_email_v1(timestamptz, timestamptz, boolean);

CREATE OR REPLACE FUNCTION public.get_analytics_data_bh_email_v1(
  p_from           timestamptz DEFAULT (now() - interval '30 days'),
  p_to             timestamptz DEFAULT now(),
  p_include_admins boolean     DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '30s'
AS $rpc$
DECLARE
  result jsonb;
BEGIN
  WITH
  -- Envios da janela, ja classificados
  el AS (
    SELECT
      e.id,
      e.recipient_user_id,
      e.recipient_email,
      e.email_type,
      e.status,
      e.error_message,
      e.created_at,
      lower(split_part(e.recipient_email, '@', 2))          AS domain,
      e.metadata->>'utm_campaign'                           AS utm_campaign,
      e.metadata->>'campaign'                               AS campaign,
      coalesce(e.metadata->>'utm_campaign',
               e.metadata->>'campaign',
               e.email_type)                                AS campaign_key,
      e.metadata->>'subject_source'                         AS subject_source,
      e.metadata->>'tier'                                   AS tier,
      nullif(e.metadata->>'doc_count','')::int              AS doc_count,
      public.bh_email_category(e.email_type)                AS category,
      public.bh_email_cadence(e.email_type)                 AS cadence,
      public.bh_email_stage(e.email_type)                   AS stage,
      (e.status = 'sent')                                   AS ok
    FROM public.email_log e
    WHERE e.created_at BETWEEN p_from AND p_to
      AND (
        p_include_admins
        OR NOT EXISTS (
          SELECT 1 FROM public.profiles p
          WHERE p.user_id = e.recipient_user_id AND p.is_admin = true
        )
      )
  ),
  -- Primeiro clique por (usuario, campanha) -- desfaz a stickiness da UTM
  fc AS (
    SELECT u.user_id, u.utm_campaign AS key, min(u.event_ts) AS first_ts
    FROM public.usage_events u
    WHERE u.utm_source = 'email'
      AND u.utm_campaign IS NOT NULL
      AND u.user_id IS NOT NULL
    GROUP BY 1, 2
  ),
  -- Expande cada envio nas suas chaves candidatas de match
  el_keys AS (
    SELECT e.id, e.recipient_user_id, e.created_at, k.key
    FROM el e
    CROSS JOIN LATERAL (
      SELECT DISTINCT x AS key
      FROM unnest(ARRAY[e.utm_campaign, e.campaign, e.email_type]) AS x
      WHERE x IS NOT NULL
    ) k
  ),
  -- Envio -> primeiro clique valido (pos-envio, ate 30d)
  sc AS (
    SELECT e.*, cl.first_click_ts,
           (cl.first_click_ts IS NOT NULL) AS clicked,
           extract(epoch FROM (cl.first_click_ts - e.created_at)) / 3600.0 AS hours_to_click
    FROM el e
    LEFT JOIN (
      SELECT ek.id, min(f.first_ts) AS first_click_ts
      FROM el_keys ek
      JOIN fc f
        ON f.user_id = ek.recipient_user_id
       AND f.key     = ek.key
       AND f.first_ts >= ek.created_at
       AND f.first_ts <  ek.created_at + interval '30 days'
      GROUP BY ek.id
    ) cl ON cl.id = e.id
  ),
  -- Sessoes que carregam UTM de email
  es_all AS (
    SELECT u.session_id,
           (array_agg(u.user_id ORDER BY u.event_ts)
              FILTER (WHERE u.user_id IS NOT NULL))[1] AS user_id,
           (array_agg(u.utm_campaign ORDER BY u.event_ts))[1] AS key,
           min(u.event_ts) AS started_at
    FROM public.usage_events u
    WHERE u.utm_source = 'email' AND u.session_id IS NOT NULL
    GROUP BY u.session_id
  ),
  -- So a PRIMEIRA sessao por (usuario, campanha) e um clique de verdade.
  -- As seguintes sao carryover da UTM sticky (o usuario volta organicamente
  -- meses depois e a UTM antiga continua sendo reemitida) -- contar todas
  -- inflava o funil em ~10x (272 "sessoes" para 24 cliques reais).
  es AS (
    SELECT DISTINCT ON (user_id, key) session_id, user_id, key, started_at
    FROM es_all
    ORDER BY user_id, key, started_at
  ),
  es_w AS (
    SELECT * FROM es WHERE started_at BETWEEN p_from AND p_to
  ),
  es_f AS (
    SELECT s.session_id, s.key,
           EXISTS (SELECT 1 FROM public.usage_events e
                    WHERE e.session_id = s.session_id AND e.event_name = 'auth_login')        AS has_login,
           EXISTS (SELECT 1 FROM public.usage_events e
                    WHERE e.session_id = s.session_id AND e.event_name LIKE 'paywall%')       AS has_paywall,
           EXISTS (SELECT 1 FROM public.usage_events e
                    WHERE e.session_id = s.session_id AND e.event_name = 'payment_succeeded') AS has_payment
    FROM es_w s
  )

  SELECT jsonb_build_object(

    -- ===== KPIs =====
    'email_overview', (
      SELECT jsonb_build_object(
        'total_sent',        count(*),
        'delivered',         count(*) FILTER (WHERE ok),
        'failed',            count(*) FILTER (WHERE NOT ok),
        'fail_rate',         round((count(*) FILTER (WHERE NOT ok))::numeric * 100 / nullif(count(*),0), 2),
        'unique_recipients', count(DISTINCT recipient_user_id),
        'unique_emails',     count(DISTINCT recipient_email),
        'email_types',       count(DISTINCT email_type),
        'categories',        count(DISTINCT category),
        'campaigns',         count(DISTINCT campaign_key),
        'sends_per_recipient', round(count(*)::numeric / nullif(count(DISTINCT recipient_user_id),0), 2),
        'clicked_sends',     count(*) FILTER (WHERE clicked),
        'unique_clickers',   count(DISTINCT recipient_user_id) FILTER (WHERE clicked),
        'ctr_sends',         round((count(*) FILTER (WHERE clicked))::numeric * 100 / nullif(count(*) FILTER (WHERE ok),0), 2),
        'ctr_recipients',    round((count(DISTINCT recipient_user_id) FILTER (WHERE clicked))::numeric * 100
                                   / nullif(count(DISTINCT recipient_user_id),0), 2),
        'median_hours_to_click', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY hours_to_click)::numeric, 1),
        'domains',           count(DISTINCT domain)
      ) FROM sc
    ),

    -- ===== Taxonomia: categoria x cadencia x estagio =====
    'email_by_category', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT category, cadence, stage,
               count(*) AS sent,
               count(*) FILTER (WHERE ok) AS delivered,
               count(*) FILTER (WHERE NOT ok) AS failed,
               count(DISTINCT email_type) AS types,
               count(DISTINCT recipient_user_id) AS recipients,
               count(*) FILTER (WHERE clicked) AS clicks,
               count(DISTINCT recipient_user_id) FILTER (WHERE clicked) AS clickers,
               round((count(*) FILTER (WHERE clicked))::numeric * 100 / nullif(count(*) FILTER (WHERE ok),0), 2) AS ctr,
               min(created_at)::date AS first_send,
               max(created_at)::date AS last_send
        FROM sc GROUP BY 1,2,3 ORDER BY sent DESC
      ) t
    ),
    'email_by_cadence', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT cadence,
               count(*) AS sent,
               count(DISTINCT recipient_user_id) AS recipients,
               count(*) FILTER (WHERE clicked) AS clicks,
               round((count(*) FILTER (WHERE clicked))::numeric * 100 / nullif(count(*) FILTER (WHERE ok),0), 2) AS ctr
        FROM sc GROUP BY 1 ORDER BY sent DESC
      ) t
    ),
    'email_by_stage', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT stage,
               count(*) AS sent,
               count(DISTINCT recipient_user_id) AS recipients,
               count(*) FILTER (WHERE clicked) AS clicks,
               round((count(*) FILTER (WHERE clicked))::numeric * 100 / nullif(count(*) FILTER (WHERE ok),0), 2) AS ctr
        FROM sc GROUP BY 1 ORDER BY sent DESC
      ) t
    ),

    -- ===== Tabela mestra por email_type =====
    'email_by_type', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT email_type, category, cadence, stage,
               count(*) AS sent,
               count(*) FILTER (WHERE ok) AS delivered,
               count(*) FILTER (WHERE NOT ok) AS failed,
               round((count(*) FILTER (WHERE NOT ok))::numeric * 100 / nullif(count(*),0), 2) AS fail_rate,
               count(DISTINCT recipient_user_id) AS recipients,
               count(*) FILTER (WHERE clicked) AS clicks,
               count(DISTINCT recipient_user_id) FILTER (WHERE clicked) AS clickers,
               round((count(*) FILTER (WHERE clicked))::numeric * 100 / nullif(count(*) FILTER (WHERE ok),0), 2) AS ctr,
               round(percentile_cont(0.5) WITHIN GROUP (ORDER BY hours_to_click)::numeric, 1) AS median_hours_to_click,
               min(created_at)::date AS first_send,
               max(created_at)::date AS last_send
        FROM sc GROUP BY 1,2,3,4 ORDER BY sent DESC
      ) t
    ),

    -- ===== Performance por campanha (chave de atribuicao) =====
    'email_campaigns', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT c.campaign_key, c.category, c.cadence,
               c.sent, c.recipients, c.clicks, c.clickers, c.ctr,
               c.median_hours_to_click, c.first_send, c.last_send,
               coalesce(f.sessions, 0)         AS sessions,
               coalesce(f.sessions_login, 0)   AS sessions_login,
               coalesce(f.sessions_paywall, 0) AS sessions_paywall,
               coalesce(f.sessions_payment, 0) AS sessions_payment
        FROM (
          SELECT campaign_key,
                 min(category) AS category,
                 min(cadence)  AS cadence,
                 count(*) AS sent,
                 count(DISTINCT recipient_user_id) AS recipients,
                 count(*) FILTER (WHERE clicked) AS clicks,
                 count(DISTINCT recipient_user_id) FILTER (WHERE clicked) AS clickers,
                 round((count(*) FILTER (WHERE clicked))::numeric * 100 / nullif(count(*) FILTER (WHERE ok),0), 2) AS ctr,
                 round(percentile_cont(0.5) WITHIN GROUP (ORDER BY hours_to_click)::numeric, 1) AS median_hours_to_click,
                 min(created_at)::date AS first_send,
                 max(created_at)::date AS last_send
          FROM sc GROUP BY 1
        ) c
        LEFT JOIN (
          SELECT key,
                 count(*) AS sessions,
                 count(*) FILTER (WHERE has_login)   AS sessions_login,
                 count(*) FILTER (WHERE has_paywall) AS sessions_paywall,
                 count(*) FILTER (WHERE has_payment) AS sessions_payment
          FROM es_f GROUP BY 1
        ) f ON f.key = c.campaign_key
        ORDER BY c.sent DESC LIMIT 100
      ) t
    ),

    -- ===== Serie diaria =====
    'email_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               category,
               count(*) AS sent,
               count(*) FILTER (WHERE NOT ok) AS failed,
               count(*) FILTER (WHERE clicked) AS clicks,
               count(DISTINCT recipient_user_id) AS recipients
        FROM sc GROUP BY 1,2 ORDER BY 1 ASC
      ) t
    ),

    -- ===== Funil de clique (sessoes vindas de email na janela) =====
    'email_click_funnel', (
      SELECT jsonb_build_object(
        'sent',             (SELECT count(*) FROM sc),
        'delivered',        (SELECT count(*) FROM sc WHERE ok),
        'recipients',       (SELECT count(DISTINCT recipient_user_id) FROM sc),
        'clickers',         (SELECT count(DISTINCT recipient_user_id) FROM sc WHERE clicked),
        'sessions',         (SELECT count(*) FROM es_f),
        'sessions_login',   (SELECT count(*) FROM es_f WHERE has_login),
        'sessions_paywall', (SELECT count(*) FROM es_f WHERE has_paywall),
        'sessions_payment', (SELECT count(*) FROM es_f WHERE has_payment)
      )
    ),

    -- ===== Tempo ate o clique =====
    'email_time_to_click', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT b.bucket, b.ord, count(sc.id) AS cnt
        FROM (VALUES ('< 1h',1),('1-6h',2),('6-24h',3),('1-3d',4),('3-7d',5),('7d+',6)) AS b(bucket, ord)
        LEFT JOIN sc ON sc.clicked AND b.bucket = CASE
            WHEN sc.hours_to_click < 1   THEN '< 1h'
            WHEN sc.hours_to_click < 6   THEN '1-6h'
            WHEN sc.hours_to_click < 24  THEN '6-24h'
            WHEN sc.hours_to_click < 72  THEN '1-3d'
            WHEN sc.hours_to_click < 168 THEN '3-7d'
            ELSE '7d+' END
        GROUP BY b.bucket, b.ord ORDER BY b.ord
      ) t
    ),

    -- ===== Dominios (proxy de deliverability) =====
    'email_domains', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT domain,
               count(*) AS sent,
               count(*) FILTER (WHERE NOT ok) AS failed,
               round((count(*) FILTER (WHERE NOT ok))::numeric * 100 / nullif(count(*),0), 2) AS fail_rate,
               count(DISTINCT recipient_user_id) AS recipients,
               count(*) FILTER (WHERE clicked) AS clicks,
               round((count(*) FILTER (WHERE clicked))::numeric * 100 / nullif(count(*) FILTER (WHERE ok),0), 2) AS ctr
        FROM sc GROUP BY 1 ORDER BY sent DESC LIMIT 20
      ) t
    ),

    -- ===== Assunto gerado por IA vs fallback (digests) =====
    'email_subject_source', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT coalesce(subject_source, '(n/a)') AS subject_source,
               count(*) AS sent,
               count(*) FILTER (WHERE clicked) AS clicks,
               round((count(*) FILTER (WHERE clicked))::numeric * 100 / nullif(count(*) FILTER (WHERE ok),0), 2) AS ctr,
               round(avg(doc_count)::numeric, 1) AS avg_doc_count
        FROM sc WHERE subject_source IS NOT NULL
        GROUP BY 1 ORDER BY sent DESC
      ) t
    ),

    -- ===== Frequencia / fadiga =====
    'email_frequency', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT b.bucket, b.ord, count(u.recipient_user_id) AS users
        FROM (VALUES ('1',1),('2-3',2),('4-10',3),('11-30',4),('31+',5)) AS b(bucket, ord)
        LEFT JOIN (
          SELECT recipient_user_id, count(*) AS n FROM sc
          WHERE recipient_user_id IS NOT NULL GROUP BY 1
        ) u ON b.bucket = CASE
            WHEN u.n = 1   THEN '1'
            WHEN u.n <= 3  THEN '2-3'
            WHEN u.n <= 10 THEN '4-10'
            WHEN u.n <= 30 THEN '11-30'
            ELSE '31+' END
        GROUP BY b.bucket, b.ord ORDER BY b.ord
      ) t
    ),

    -- ===== Destinatarios mais impactados =====
    'email_top_recipients', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT recipient_email AS email,
               count(*) AS sent,
               count(DISTINCT email_type) AS types,
               count(DISTINCT category) AS categories,
               count(*) FILTER (WHERE clicked) AS clicks,
               round((count(*) FILTER (WHERE clicked))::numeric * 100 / nullif(count(*) FILTER (WHERE ok),0), 2) AS ctr,
               max(created_at)::date AS last_send,
               max(first_click_ts)::date AS last_click
        FROM sc GROUP BY 1 ORDER BY sent DESC LIMIT 50
      ) t
    ),

    -- ===== Falhas =====
    'email_failures', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT email_type, category,
               coalesce(left(error_message, 120), '(sem mensagem)') AS error_message,
               count(*) AS cnt,
               min(created_at)::date AS first_seen,
               max(created_at)::date AS last_seen
        FROM sc WHERE NOT ok
        GROUP BY 1,2,3 ORDER BY cnt DESC LIMIT 30
      ) t
    ),

    -- ===== Hora de envio x clique =====
    'email_send_hour', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT extract(hour FROM created_at AT TIME ZONE 'America/Sao_Paulo')::int AS hour,
               count(*) AS sent,
               count(*) FILTER (WHERE clicked) AS clicks,
               round((count(*) FILTER (WHERE clicked))::numeric * 100 / nullif(count(*) FILTER (WHERE ok),0), 2) AS ctr
        FROM sc GROUP BY 1 ORDER BY 1
      ) t
    ),

    -- ===== Base opt-in dos digests (estado atual, all-time por natureza) =====
    'email_optin', (
      SELECT jsonb_build_object(
        'total_prefs',      count(*),
        'daily_email',      count(*) FILTER (WHERE daily_cvm_email),
        'weekly_email',     count(*) FILTER (WHERE weekly_cvm_email),
        'daily_telegram',   count(*) FILTER (WHERE daily_cvm_telegram),
        'weekly_telegram',  count(*) FILTER (WHERE weekly_cvm_telegram),
        'daily_whatsapp',   count(*) FILTER (WHERE daily_cvm_whatsapp),
        'weekly_whatsapp',  count(*) FILTER (WHERE weekly_cvm_whatsapp),
        'any_email_digest', count(*) FILTER (WHERE daily_cvm_email OR weekly_cvm_email)
      ) FROM public.notification_preferences
    ),

    -- ===== Segmentacao por tier (metadata dos digests) =====
    'email_by_tier', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT tier,
               count(*) AS sent,
               count(DISTINCT recipient_user_id) AS recipients,
               count(*) FILTER (WHERE clicked) AS clicks,
               round((count(*) FILTER (WHERE clicked))::numeric * 100 / nullif(count(*) FILTER (WHERE ok),0), 2) AS ctr
        FROM sc WHERE tier IS NOT NULL GROUP BY 1 ORDER BY sent DESC
      ) t
    ),

    'meta', jsonb_build_object(
      'from', p_from,
      'to', p_to,
      'include_admins', p_include_admins,
      'rpc_version', 'bh_email_v1_20260828',
      'click_model', 'first-touch por (usuario, utm_campaign), pos-envio, janela de 30d',
      'open_tracking', false,
      'open_tracking_note', 'email_log nao registra aberturas e nao ha webhook do provedor; CTR e o proxy disponivel'
    )
  ) INTO result;

  RETURN result;
END;
$rpc$;

GRANT EXECUTE ON FUNCTION public.get_analytics_data_bh_email_v1(timestamptz, timestamptz, boolean)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.get_analytics_data_bh_email_v1(timestamptz, timestamptz, boolean) IS
  'Email analytics para o dashboard iAcoes. Classifica email_log em categoria/cadencia/estagio e atribui cliques via utm_source=email (first-touch). NAO ha taxa de abertura: o provedor nao envia webhooks de open.';
