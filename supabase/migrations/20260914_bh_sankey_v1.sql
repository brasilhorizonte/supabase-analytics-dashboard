-- ============================================================================
-- 20260914_bh_sankey_v1.sql
-- Diagramas de fluxo (Sankey) da plataforma iAcoes: aquisicao e engajamento.
--
-- Por que Sankey e nao mais um funil: os funis existentes (conversion_funnel,
-- paywall_v2_funnel) mostram QUANTOS caem em cada etapa, mas nao DE ONDE vem
-- quem cai nem PARA ONDE vai. Duas perguntas que so um diagrama de fluxo
-- responde:
--   1. Aquisicao -- "de qual fonte vem quem paga?" (o funil agregado diz que
--      X% paga, mas nao diz que ~todo o pagamento vem de 2 fontes).
--   2. Engajamento -- "qual feature leva a qual?" A navegacao entre features
--      nunca foi medida; `feature_usage` conta usos isolados.
--
-- Contrato de linha (identico nas duas secoes e no `iacoes_landing_sankey`):
--   {stage, source, target, value}
-- O `source` vive na coluna `stage` e o `target` na coluna `stage+1`. O
-- frontend deriva os nos a partir dos links -- nao ha lista de nos separada,
-- entao a chave de um no e (stage, label): o mesmo rotulo em stages
-- diferentes e um no diferente (essencial no fluxo de features, em que
-- 'core' aparece em todas as etapas).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_analytics_data_bh_sankey_v1(
  p_from           timestamptz DEFAULT now() - interval '30 days',
  p_to             timestamptz DEFAULT now(),
  p_include_admins boolean     DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '30s'
AS $function$
DECLARE
  result jsonb;
BEGIN
  WITH ue AS (
    SELECT e.user_id, e.session_id, e.event_name, e.feature, e.event_ts,
           e.referrer, e.utm_source
    FROM public.usage_events e
    WHERE e.event_ts BETWEEN p_from AND p_to
      AND (p_include_admins OR NOT EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.user_id = e.user_id AND p.is_admin = true))
  ),
  -- ===== Aquisicao: um no por usuario em cada etapa (nivel usuario, nao
  -- sessao -- o ciclo paywall -> pagamento costuma cruzar varias sessoes).
  first_touch AS (
    SELECT DISTINCT ON (user_id) user_id, referrer, utm_source
    FROM ue WHERE event_name = 'session_start' AND user_id IS NOT NULL
    ORDER BY user_id, event_ts
  ),
  usr AS (
    SELECT ue.user_id,
           -- Largura de uso, nao login: `auth_login` so dispara no login
           -- explicito, entao um retornante com sessao ja autenticada nao emite
           -- o evento -- usa-lo como etapa produziria "Sem login -> Pagou".
           count(DISTINCT feature) FILTER (WHERE feature IS NOT NULL AND feature <> '') AS n_features,
           bool_or(event_name IN ('paywall_block','paywall_teaser_view','credit_exhausted_paywall_shown',
                                  'export_paywall_shown','paywall_v2_banner_shown','paywall_hint_shown')) AS has_paywall,
           bool_or(event_name IN ('checkout_start','credit_exhausted_checkout_start')) AS has_checkout,
           bool_or(event_name IN ('payment_succeeded','subscription_start','trial_start')) AS has_payment
    FROM ue WHERE ue.user_id IS NOT NULL
    GROUP BY ue.user_id
  ),
  acq AS (
    SELECT u.user_id,
           CASE
             WHEN ft.user_id IS NULL THEN 'Fonte nao registrada'
             WHEN ft.referrer ILIKE '%iacoes%' THEN 'Landing iAcoes'
             WHEN ft.referrer ILIKE '%lovable%' OR ft.referrer ILIKE '%localhost%' THEN 'Dev'
             WHEN ft.referrer ILIKE '%brasilhorizonte%' THEN 'Interno (app)'
             WHEN ft.referrer ILIKE '%stripe.com%' THEN 'Stripe'
             WHEN ft.referrer ILIKE '%google%' THEN 'Google'
             WHEN ft.referrer ILIKE '%facebook%' OR ft.referrer ILIKE '%fbclid%' THEN 'Facebook'
             WHEN ft.referrer ILIKE '%instagram%' THEN 'Instagram'
             WHEN ft.referrer ILIKE '%twitter%' OR ft.referrer ILIKE '%://x.com%' OR ft.referrer ILIKE '%://t.co/%' THEN 'Twitter/X'
             WHEN ft.referrer ILIKE '%linkedin%' THEN 'LinkedIn'
             WHEN ft.referrer ILIKE '%whatsapp%' THEN 'WhatsApp'
             WHEN ft.referrer ILIKE '%telegram%' OR ft.referrer ILIKE '%t.me%' THEN 'Telegram'
             WHEN ft.referrer ILIKE '%youtube%' OR ft.referrer ILIKE '%youtu.be%' THEN 'YouTube'
             -- Sem referrer util: cai pra UTM antes de virar 'Direto'
             WHEN ft.utm_source IS NOT NULL AND ft.utm_source <> '' THEN 'utm: ' || ft.utm_source
             WHEN ft.referrer IS NULL OR ft.referrer = '' THEN 'Direto'
             ELSE 'Outro'
           END AS fonte,
           CASE WHEN u.n_features >= 3 THEN 'Explorou (3+ features)'
                WHEN u.n_features >= 1 THEN 'Usou 1-2 features'
                ELSE 'So abriu' END AS atividade,
           CASE WHEN u.has_payment  THEN 'Pagou / assinou'
                WHEN u.has_checkout THEN 'Checkout sem pagar'
                WHEN u.has_paywall  THEN 'Parou no paywall'
                ELSE 'Sem sinal de compra' END AS desfecho
    FROM usr u LEFT JOIN first_touch ft USING (user_id)
  ),
  -- Duas etapas porque Postgres nao aceita window function aninhada
  -- (dense_rank sobre count(*) OVER ...) numa unica projecao.
  acq_counted AS (
    SELECT a.*, count(*) OVER (PARTITION BY a.fonte) AS cnt_fonte FROM acq a
  ),
  acq_ranked AS (
    SELECT c.*, dense_rank() OVER (ORDER BY cnt_fonte DESC, fonte) AS rk FROM acq_counted c
  ),
  acq_node AS (
    SELECT CASE WHEN rk <= 8 THEN fonte ELSE 'Outras fontes' END AS n_fonte,
           atividade, desfecho
    FROM acq_ranked
  ),
  -- ===== Engajamento: transicoes entre features dentro da sessao.
  -- `prev IS DISTINCT FROM feature` colapsa repeticoes consecutivas da mesma
  -- feature -- sem isso o fluxo vira quase so auto-loop (uma sessao emite
  -- dezenas de eventos seguidos da mesma feature).
  ev AS (
    SELECT session_id, feature, event_ts FROM ue
    WHERE feature IS NOT NULL AND feature <> '' AND session_id IS NOT NULL
  ),
  seq AS (
    SELECT session_id, feature, event_ts,
           lag(feature) OVER (PARTITION BY session_id ORDER BY event_ts) AS prev
    FROM ev
  ),
  steps AS (
    SELECT session_id, feature,
           row_number() OVER (PARTITION BY session_id ORDER BY event_ts) AS rn
    FROM seq WHERE prev IS DISTINCT FROM feature
  ),
  frank AS (
    SELECT feature, dense_rank() OVER (ORDER BY count(*) DESC, feature) AS rk
    FROM steps WHERE rn <= 5 GROUP BY feature
  ),
  labeled AS (
    SELECT s.session_id, s.rn, CASE WHEN r.rk <= 8 THEN s.feature ELSE 'Outros' END AS f
    FROM steps s JOIN frank r USING (feature) WHERE s.rn <= 5
  ),
  eng_pairs AS (
    SELECT l1.rn AS st, l1.f AS source, coalesce(l2.f, 'Encerrou sessao') AS target
    FROM labeled l1
    LEFT JOIN labeled l2 ON l2.session_id = l1.session_id AND l2.rn = l1.rn + 1
    WHERE l1.rn <= 4
  )
  SELECT jsonb_build_object(
    'sankey_acquisition', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT 0 AS stage, n_fonte   AS source, atividade AS target, count(*)::int AS value
        FROM acq_node GROUP BY 1, 2, 3
        UNION ALL
        SELECT 1 AS stage, atividade AS source, desfecho  AS target, count(*)::int AS value
        FROM acq_node GROUP BY 1, 2, 3
        ORDER BY 1, 4 DESC
      ) t
    ),
    'sankey_engagement', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT st - 1 AS stage, source, target, count(*)::int AS value
        FROM eng_pairs GROUP BY 1, 2, 3 ORDER BY 1, 4 DESC
      ) t
    ),
    -- Totais para o subtitulo dos graficos (evita o frontend recomputar
    -- somando links, que conta em dobro quando um no aparece em 2 stages).
    'sankey_overview', jsonb_build_object(
      'acq_users',       (SELECT count(*)::int FROM acq_node),
      'acq_paid',        (SELECT count(*)::int FROM acq_node WHERE desfecho = 'Pagou / assinou'),
      'eng_sessions',    (SELECT count(DISTINCT session_id)::int FROM labeled),
      'eng_multi_feature', (SELECT count(*)::int FROM (
                              SELECT session_id FROM labeled GROUP BY session_id HAVING count(*) > 1) x)
    ),
    'meta', jsonb_build_object(
      'from', p_from, 'to', p_to,
      'rpc_version', 'bh_sankey_v1_20260914',
      'include_admins', p_include_admins,
      'acq_grain', 'usuario (first-touch de session_start)',
      'eng_grain', 'sessao (transicoes entre features, ate 5 etapas)'
    )
  ) INTO result;

  RETURN result;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_analytics_data_bh_sankey_v1(timestamptz, timestamptz, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_analytics_data_bh_sankey_v1(timestamptz, timestamptz, boolean) TO service_role;
