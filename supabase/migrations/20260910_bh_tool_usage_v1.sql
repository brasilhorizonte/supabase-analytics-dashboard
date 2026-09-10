-- =====================================================================
-- 20260910_bh_tool_usage_v1.sql
-- Projeto: brasilhorizonte (dawvgbopyemcayavcatd)
--
-- NEW RPC get_analytics_data_bh_tool_usage_v1(p_from, p_to) — secao
-- "Uso das ferramentas" da aba iAcoes > Engajamento. Chave: tool_usage.
--
-- Por ferramenta: ABRIRAM (visita), ESCOLHERAM (clique vindo de outra aba),
-- USARAM (evento de acao), VOLTARAM (visitou em 2+ dias BRT), data do 1o
-- evento de acao de usuario real e os eventos de acao que ainda nao
-- chegaram de ninguem (acao_pendentes).
--
-- Por que existe (analise de 10/09/2026): tab_view mede visita, nao uso.
-- Rankings, Radar, Score, Teses, CAPE, Planejar e o save do Validador so
-- ganharam evento de acao em 10/09 (repo dashbrasilhorizonte,
-- src/lib/toolActionEvents.ts). Ate o deploy na main esses eventos nao
-- existem para usuario real; o painel precisa dizer "ainda sem dado" em vez
-- de mostrar zero — e para isso que serve acao_pendentes.
--
-- Armadilhas de medicao embutidas:
--   * Em home/workspace o tab_view vem com properties->>'tab' NULO — essas
--     ferramentas sao medidas por evento proprio (visit_events).
--   * DEFAULT_TABS do App (dashboard, valuai, reports) inflam a visita com
--     aterrissagem. 'abriram' e o bruto (teto natural do % de uso);
--     'escolheram' e o clique vindo de outra aba da mesma secao.
--   * raiox_view e macro_beta_view disparam no RENDER: nao sao acao. Raio-X
--     fica sem evento; Macro usa macro_beta_run_success/_error.
--   * qualitativo_run nao tem emissor no front: sai do servidor quando a
--     analise roda — vale como uso.
--
-- ⚠️ O catalogo de ferramentas (CTE tools) duplica o do front por
-- necessidade (repos diferentes). Evento de acao novo no front => editar
-- aqui tambem. acao_pendentes denuncia o caso inverso (evento listado aqui
-- que ninguem emite).
--
-- Admins: sempre excluidos (le usage_events_clean). Contas admin de QA da
-- lab gravam no banco de PRODUCAO — sem o filtro, "acao_desde" apareceria
-- a partir de teste interno.
--
-- Performance: o filtro de event_name vai como = ANY(array) para virar
-- Index Cond. ⚠️ O cast em ANY((SELECT arr FROM evlist)::text[]) e
-- obrigatorio: sem ele o Postgres le ANY(subconsulta) comparando com cada
-- LINHA (text = text[], erro 42883), nao com cada elemento do array. Com "event_name = 'tab_view' OR event_name IN (subconsulta)"
-- o plano lia 110k linhas e levava 5,4 s em 90d; assim o preset Max (desde
-- 2026-01-07) le ~45k linhas em ~0,5 s.
--
-- Seguranca: SECURITY DEFINER (usage_events_clean tem REVOKE de PUBLIC) +
-- guard de role + EXECUTE so para service_role (a Edge Function
-- analytics-dashboard chama com BH_SERVICE_ROLE_KEY). CREATE FUNCTION
-- concede EXECUTE a PUBLIC por padrao e o Supabase ainda da default
-- privileges a anon/authenticated — o REVOKE abaixo e obrigatorio.
-- statement_timeout em nivel de funcao e inerte no path REST (ver
-- 20260818_v2_impl_timeout_90s.sql) — nao foi setado.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.get_analytics_data_bh_tool_usage_v1(
  p_from timestamptz DEFAULT (now() - interval '30 days'),
  p_to   timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  WITH tools(ord, tool, label, secao, tab_id, is_default, visit_events, action_events, action_feature, action_action, step2_label, step2_events) AS (VALUES
    ( 1,'valuai',      'ValuAI',              'ianalista','valuai',      true,  NULL::text[], ARRAY['valuai_analysis_start'], NULL::text, NULL::text, NULL::text, NULL::text[]),
    ( 2,'dashboard',   'Dashboard',           'ialocador','dashboard',   true,  NULL, NULL, NULL, NULL, NULL, NULL),
    ( 3,'portfolio',   'Carteira',            'ialocador','portfolio',   false, NULL, ARRAY['portfolio_save'], NULL, NULL, NULL, NULL),
    ( 4,'rankings',    'Rankings',            'ialocador','rankings',    false, NULL, ARRAY['rankings_sort_applied'], NULL, NULL, NULL, NULL),
    ( 5,'qualitativo', 'Qualitativo',         'ianalista','qualitativo', false, NULL, ARRAY['qualitativo_run'], NULL, NULL, NULL, NULL),
    ( 6,'score',       'Score',               'ianalista','score',       false, NULL, ARRAY['score_card_opened'], NULL, NULL, NULL, NULL),
    ( 7,'radar',       'Radar',               'ialocador','radar',       false, NULL, ARRAY['radar_filter_applied'], NULL, NULL, NULL, NULL),
    ( 8,'optimization','Otimizador',          'ialocador','optimization',false, NULL, ARRAY['optimization_run'], NULL, NULL, NULL, NULL),
    ( 9,'macro',       'Macro',               'ialocador','macro',       false, NULL, ARRAY['macro_beta_run_success','macro_beta_run_error'], NULL, NULL, NULL, NULL),
    (10,'validador',   'Validador',           'ianalista','validador',   false, NULL, ARRAY['analysis_run'], 'validador', 'start', 'salvaram', ARRAY['thesis_validation_saved']),
    (11,'teses',       'Teses',               'ianalista','teses',       false, NULL, ARRAY['thesis_card_expanded','thesis_manual_create'], NULL, NULL, NULL, NULL),
    (12,'raiox',       'Raio-X',              'ianalista','raiox',       false, NULL, NULL, NULL, NULL, NULL, NULL),
    (13,'dividendos',  'Dividendos',          'ialocador','dividendos',  false, NULL, ARRAY['dividends_window_switched','dividends_portfolio_switched'], NULL, NULL, NULL, NULL),
    (14,'cape',        'CAPE',                'ialocador','cape',        false, NULL, ARRAY['cape_window_switched','cape_portfolio_created'], NULL, NULL, NULL, NULL),
    (15,'reports',     'Texto (Research)',    'research', 'reports',     true,  NULL, ARRAY['report_view'], NULL, NULL, NULL, NULL),
    (16,'content',     'Videos (Research)',   'research', 'content',     false, NULL, NULL, NULL, NULL, NULL, NULL),
    (17,'carteiras',   'Carteiras (Research)','research', 'carteiras',   false, NULL, NULL, NULL, NULL, NULL, NULL),
    (18,'valuation',   'Arquivos (Research)', 'research', 'valuation',   false, NULL, NULL, NULL, NULL, NULL, NULL),
    (19,'planejar',    'Planejar',            'research', 'planejar',    false, NULL, ARRAY['planejar_calculator_used'], NULL, NULL, NULL, NULL),
    (20,'airton_web',  'AIrton (web)',        'workspace', NULL,         false, ARRAY['companion_opened','workspace_cockpit_viewed'], ARRAY['companion_message_sent'], NULL, NULL, NULL, NULL),
    (21,'airton_wa',   'AIrton (WhatsApp)',   'whatsapp',  NULL,         false, ARRAY['whatsapp_message_received'], ARRAY['whatsapp_message_received'], NULL, NULL, NULL, NULL),
    (22,'notificacoes','Notificacoes',        'home',      NULL,         false, ARRAY['notifications_central_viewed'], NULL, NULL, NULL, NULL, NULL)
  ),
  evlist AS (
    SELECT array_agg(DISTINCT x) AS arr
    FROM tools, unnest(ARRAY['tab_view'] || coalesce(visit_events, '{}') || coalesce(action_events, '{}') || coalesce(step2_events, '{}')) x
  ),
  actlist AS (
    SELECT array_agg(DISTINCT x) AS arr
    FROM tools, unnest(coalesce(action_events, '{}') || coalesce(step2_events, '{}')) x
  ),
  ev AS MATERIALIZED (
    SELECT e.user_id, e.event_name, e.feature, e.action, e.section,
           e.properties->>'tab'              AS tab,
           e.properties->>'previous_section' AS prev_section,
           e.properties->>'previous_tab'     AS prev_tab,
           (e.event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS d
    FROM public.usage_events_clean e
    WHERE e.event_ts >= p_from AND e.event_ts < p_to
      AND e.user_id IS NOT NULL
      AND e.event_name = ANY((SELECT arr FROM evlist)::text[])
  ),
  visits AS (
    SELECT t.tool, e.user_id, e.d,
           (NOT t.is_default OR (e.prev_section = t.secao AND coalesce(e.prev_tab, '') <> t.tab_id)) AS deliberate
    FROM tools t
    JOIN ev e ON e.event_name = 'tab_view' AND e.section = t.secao AND e.tab = t.tab_id
    UNION ALL
    SELECT t.tool, e.user_id, e.d, true
    FROM tools t CROSS JOIN unnest(t.visit_events) v(n)
    JOIN ev e ON e.event_name = v.n
  ),
  vu AS (
    SELECT tool, user_id, count(DISTINCT d) AS dias, bool_or(deliberate) AS escolheu
    FROM visits GROUP BY 1, 2
  ),
  acts AS (
    SELECT DISTINCT t.tool, e.user_id
    FROM tools t CROSS JOIN unnest(t.action_events) a(n)
    JOIN ev e ON e.event_name = a.n
     AND (t.action_feature IS NULL OR e.feature = t.action_feature)
     AND (t.action_action  IS NULL OR e.action  = t.action_action)
  ),
  s2 AS (
    SELECT DISTINCT t.tool, e.user_id
    FROM tools t CROSS JOIN unnest(t.step2_events) s(n)
    JOIN ev e ON e.event_name = s.n
  ),
  firsts AS (
    -- All-time, de proposito: "desde quando o evento existe" nao depende do
    -- periodo selecionado no painel.
    SELECT event_name, min(event_ts) AS first_ts
    FROM public.usage_events_clean
    WHERE event_name = ANY((SELECT arr FROM actlist)::text[])
    GROUP BY 1
  )
  SELECT jsonb_build_object('tool_usage', coalesce(jsonb_agg(jsonb_build_object(
      'ord',             t.ord,
      'tool',            t.tool,
      'label',           t.label,
      'secao',           t.secao,
      'is_default',      t.is_default,
      'abriram',         (SELECT count(*) FROM vu WHERE vu.tool = t.tool),
      'escolheram',      (SELECT count(*) FROM vu WHERE vu.tool = t.tool AND vu.escolheu),
      'voltaram',        (SELECT count(*) FROM vu WHERE vu.tool = t.tool AND vu.dias >= 2),
      'usaram',          CASE WHEN t.action_events IS NULL THEN NULL
                              ELSE (SELECT count(*) FROM acts WHERE acts.tool = t.tool) END,
      'uso_eh_visita',   coalesce(t.visit_events = t.action_events, false),
      'acao_eventos',    to_jsonb(coalesce(t.action_events, '{}')),
      'acao_desde',      (SELECT (min(f.first_ts) AT TIME ZONE 'America/Sao_Paulo')::date
                            FROM firsts f WHERE f.event_name = ANY(t.action_events)),
      'acao_pendentes',  to_jsonb(ARRAY(SELECT n FROM unnest(coalesce(t.action_events, '{}')) n
                                         WHERE NOT EXISTS (SELECT 1 FROM firsts f WHERE f.event_name = n))),
      'etapa2_label',    t.step2_label,
      'etapa2_usuarios', CASE WHEN t.step2_events IS NULL THEN NULL
                              ELSE (SELECT count(*) FROM s2 WHERE s2.tool = t.tool) END,
      'etapa2_pendente', CASE WHEN t.step2_events IS NULL THEN NULL
                              ELSE NOT EXISTS (SELECT 1 FROM firsts f WHERE f.event_name = ANY(t.step2_events)) END
    ) ORDER BY t.ord), '[]'::jsonb))
  INTO result
  FROM tools t;

  RETURN result;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_analytics_data_bh_tool_usage_v1(timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_analytics_data_bh_tool_usage_v1(timestamptz, timestamptz) TO service_role;
