-- =====================================================================
-- 20260916_bh_reports_v1.sql
-- Projeto: brasilhorizonte (dawvgbopyemcayavcatd)
--
-- NEW RPC get_analytics_data_bh_reports_v1(p_from, p_to, p_include_admins)
-- — aba iAcoes > Relatorios. Chaves: reports_*.
--
-- Por que existe (16/09/2026): a aba Detalhes so tinha downloads/dia e um
-- top 15 all-time por titulo. Sem tipo, analista, setor, plano, decaimento
-- pos-publicacao, view->download ou paywall. E inflado: 336 dos 613
-- downloads (55%) eram de admins — report_downloads nao passa por
-- usage_events_clean.
--
-- Fontes:
--   * report_downloads (created_at): fonte autoritativa de download, desde
--     2025-10-14. O evento usage_events.report_download so cobre ~15%.
--   * usage_events.report_view (coluna report_id): abertura do relatorio,
--     so existe desde 2026-01-08.
--   * usage_events.passive_paywall_click com feature
--     research_report_locked_desktop/_mobile: clique em relatorio bloqueado
--     (sem report_id nas properties — so agregado).
--   * research_reports + analysts + sectors + companies: catalogo.
--
-- Plano: report_downloads nao guarda plano. Usa profiles.plan ATUAL
-- (subscription_status='active'), rotulado "plano atual" no front. Views
-- usam usage_events.plan (plano no momento do evento).
--
-- Admins: filtro por profiles.is_admin (mesmo criterio de usage_events_clean),
-- com toggle p_include_admins (default false).
--
-- Seguranca: SECURITY DEFINER + guard de role + EXECUTE so service_role
-- (mesmo padrao de 20260910_bh_tool_usage_v1.sql).
-- =====================================================================

CREATE OR REPLACE FUNCTION public.get_analytics_data_bh_reports_v1(
  p_from timestamptz DEFAULT (now() - interval '30 days'),
  p_to   timestamptz DEFAULT now(),
  p_include_admins boolean DEFAULT false
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

  WITH admins AS (
    SELECT user_id FROM public.profiles WHERE is_admin = true AND NOT p_include_admins
  ),
  cat AS MATERIALIZED (
    SELECT r.id, r.title, r.report_type::text AS report_type, r.distribution,
           r.access_tiers, r.published_date,
           c.ticker, coalesce(s.name, s2.name) AS sector, a.name AS analyst
    FROM public.research_reports r
    LEFT JOIN public.companies c ON c.id = r.company_id
    LEFT JOIN public.sectors s   ON s.id = r.sector_id
    LEFT JOIN public.sectors s2  ON s2.id = c.sector_id
    LEFT JOIN public.analysts a  ON a.id = r.analyst_id
  ),
  -- todos os downloads (sem admins), para lifetime / 1o download
  dl_all AS MATERIALIZED (
    SELECT rd.user_id, rd.report_id, rd.created_at
    FROM public.report_downloads rd
    WHERE NOT EXISTS (SELECT 1 FROM admins a WHERE a.user_id = rd.user_id)
  ),
  dl AS MATERIALIZED (
    SELECT d.user_id, d.report_id, d.created_at,
           (d.created_at AT TIME ZONE 'America/Sao_Paulo') AS ts_brt,
           (d.created_at AT TIME ZONE 'America/Sao_Paulo')::date AS day
    FROM dl_all d
    WHERE d.created_at >= p_from AND d.created_at < p_to
  ),
  vw AS MATERIALIZED (
    -- usage_events.report_id e text; cast defensivo para uuid
    SELECT e.user_id, CASE WHEN e.report_id ~* '^[0-9a-f-]{36}$' THEN e.report_id::uuid END AS report_id, e.plan,
           (e.event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day
    FROM public.usage_events e
    WHERE e.event_name = 'report_view'
      AND e.event_ts >= p_from AND e.event_ts < p_to
      AND NOT EXISTS (SELECT 1 FROM admins a WHERE a.user_id = e.user_id)
  ),
  lk AS MATERIALIZED (
    SELECT e.user_id, e.feature, e.properties->>'target_plan' AS target_plan,
           (e.event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day
    FROM public.usage_events e
    WHERE e.event_name = 'passive_paywall_click'
      AND e.feature LIKE 'research_report_locked%'
      AND e.event_ts >= p_from AND e.event_ts < p_to
      AND NOT EXISTS (SELECT 1 FROM admins a WHERE a.user_id = e.user_id)
  ),
  first_dl AS (
    SELECT user_id, min(created_at) AS first_at FROM dl_all WHERE user_id IS NOT NULL GROUP BY 1
  ),
  user_dl AS (
    SELECT user_id, count(*) AS n, count(DISTINCT report_id) AS reports, max(created_at) AS last_at
    FROM dl WHERE user_id IS NOT NULL GROUP BY 1
  ),
  prof AS (
    SELECT p.user_id,
           CASE WHEN p.subscription_status = 'active' AND p.plan IS NOT NULL THEN p.plan ELSE 'free' END AS plan_now
    FROM public.profiles p
  )
  SELECT jsonb_build_object(
    'reports_overview', (
      SELECT jsonb_build_object(
        'downloads',            (SELECT count(*) FROM dl),
        'unique_downloaders',   (SELECT count(DISTINCT user_id) FROM dl),
        'reports_downloaded',   (SELECT count(DISTINCT report_id) FROM dl),
        'catalog_total',        (SELECT count(*) FROM cat),
        'published_in_period',  (SELECT count(*) FROM cat
                                   WHERE published_date >= (p_from AT TIME ZONE 'America/Sao_Paulo')::date
                                     AND published_date <= (p_to AT TIME ZONE 'America/Sao_Paulo')::date),
        'catalog_never_downloaded', (SELECT count(*) FROM cat WHERE NOT EXISTS (SELECT 1 FROM dl_all d WHERE d.report_id = cat.id)),
        'views',                (SELECT count(*) FROM vw),
        'unique_viewers',       (SELECT count(DISTINCT user_id) FROM vw),
        'viewers_who_downloaded', (SELECT count(DISTINCT v.user_id) FROM vw v WHERE EXISTS (SELECT 1 FROM dl d WHERE d.user_id = v.user_id)),
        'locked_clicks',        (SELECT count(*) FROM lk),
        'locked_unique_users',  (SELECT count(DISTINCT user_id) FROM lk),
        'repeat_downloaders',   (SELECT count(*) FROM user_dl WHERE n >= 2),
        'new_downloaders',      (SELECT count(*) FROM first_dl WHERE first_at >= p_from AND first_at < p_to),
        'lifetime_downloads',   (SELECT count(*) FROM dl_all),
        'views_tracked_since',  '2026-01-08'
      )
    ),
    'reports_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.day), '[]'::jsonb) FROM (
        SELECT day,
               sum(downloads)::int AS downloads, sum(dl_users)::int AS unique_downloaders,
               sum(views)::int AS views, sum(v_users)::int AS unique_viewers,
               sum(locked)::int AS locked_clicks, sum(new_dl)::int AS new_downloaders
        FROM (
          SELECT day, count(*) downloads, count(DISTINCT user_id) dl_users, 0 views, 0 v_users, 0 locked, 0 new_dl FROM dl GROUP BY day
          UNION ALL SELECT day, 0, 0, count(*), count(DISTINCT user_id), 0, 0 FROM vw GROUP BY day
          UNION ALL SELECT day, 0, 0, 0, 0, count(*), 0 FROM lk GROUP BY day
          UNION ALL SELECT (first_at AT TIME ZONE 'America/Sao_Paulo')::date, 0, 0, 0, 0, 0, count(*)
                    FROM first_dl WHERE first_at >= p_from AND first_at < p_to GROUP BY 1
        ) u GROUP BY day
      ) t
    ),
    'reports_daily_by_type', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT d.day, coalesce(c.report_type, 'unknown') AS report_type, count(*) AS downloads
        FROM dl d LEFT JOIN cat c ON c.id = d.report_id
        GROUP BY 1, 2 ORDER BY 1
      ) t
    ),
    'reports_by_type', (
      SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.downloads DESC), '[]'::jsonb) FROM (
        SELECT c.report_type,
               count(DISTINCT c.id) AS catalog,
               count(DISTINCT c.id) FILTER (WHERE c.published_date >= (p_from AT TIME ZONE 'America/Sao_Paulo')::date) AS published_in_period,
               (SELECT count(*) FROM dl d JOIN cat c2 ON c2.id = d.report_id WHERE c2.report_type = c.report_type) AS downloads,
               (SELECT count(DISTINCT d.user_id) FROM dl d JOIN cat c2 ON c2.id = d.report_id WHERE c2.report_type = c.report_type) AS unique_users,
               (SELECT count(DISTINCT d.report_id) FROM dl d JOIN cat c2 ON c2.id = d.report_id WHERE c2.report_type = c.report_type) AS reports_downloaded,
               (SELECT count(*) FROM vw v JOIN cat c2 ON c2.id = v.report_id WHERE c2.report_type = c.report_type) AS views
        FROM cat c GROUP BY c.report_type
      ) t
    ),
    'reports_by_plan', (
      SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.downloads DESC), '[]'::jsonb) FROM (
        SELECT coalesce(p.plan_now, 'sem_perfil') AS plan, count(*) AS downloads, count(DISTINCT d.user_id) AS unique_users
        FROM dl d LEFT JOIN prof p ON p.user_id = d.user_id
        GROUP BY 1
      ) t
    ),
    'reports_type_by_plan', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT coalesce(p.plan_now, 'sem_perfil') AS plan, coalesce(c.report_type, 'unknown') AS report_type, count(*) AS downloads
        FROM dl d LEFT JOIN prof p ON p.user_id = d.user_id LEFT JOIN cat c ON c.id = d.report_id
        GROUP BY 1, 2
      ) t
    ),
    'reports_by_analyst', (
      SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.downloads DESC), '[]'::jsonb) FROM (
        SELECT coalesce(c.analyst, 'Sem analista') AS analyst,
               count(DISTINCT d.report_id) AS reports_downloaded,
               count(*) AS downloads, count(DISTINCT d.user_id) AS unique_users
        FROM dl d JOIN cat c ON c.id = d.report_id
        GROUP BY 1
      ) t
    ),
    'reports_by_sector', (
      SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.downloads DESC), '[]'::jsonb) FROM (
        SELECT coalesce(c.sector, 'Sem setor') AS sector,
               count(DISTINCT d.report_id) AS reports_downloaded,
               count(*) AS downloads, count(DISTINCT d.user_id) AS unique_users
        FROM dl d JOIN cat c ON c.id = d.report_id
        GROUP BY 1
      ) t
    ),
    -- Downloads no periodo por idade do relatorio (dias desde a publicacao)
    'reports_age_buckets', (
      SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.ord), '[]'::jsonb) FROM (
        SELECT CASE WHEN age IS NULL THEN 7 WHEN age <= 0 THEN 1 WHEN age <= 3 THEN 2 WHEN age <= 7 THEN 3
                    WHEN age <= 30 THEN 4 WHEN age <= 90 THEN 5 ELSE 6 END AS ord,
               CASE WHEN age IS NULL THEN 'Sem data' WHEN age <= 0 THEN 'Dia 0' WHEN age <= 3 THEN '1-3d' WHEN age <= 7 THEN '4-7d'
                    WHEN age <= 30 THEN '8-30d' WHEN age <= 90 THEN '31-90d' ELSE '90d+' END AS bucket,
               count(*) AS downloads
        FROM (SELECT (d.day - c.published_date) AS age FROM dl d JOIN cat c ON c.id = d.report_id) x
        GROUP BY 1, 2
      ) t
    ),
    'reports_weekday_hour', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT extract(isodow FROM ts_brt)::int AS dow, extract(hour FROM ts_brt)::int AS hour, count(*) AS downloads
        FROM dl GROUP BY 1, 2
      ) t
    ),
    'reports_locked_by_plan', (
      SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.clicks DESC), '[]'::jsonb) FROM (
        SELECT coalesce(target_plan, 'desconhecido') AS target_plan,
               CASE WHEN feature LIKE '%mobile' THEN 'mobile' ELSE 'desktop' END AS device,
               count(*) AS clicks, count(DISTINCT user_id) AS unique_users
        FROM lk GROUP BY 1, 2
      ) t
    ),
    -- Catalogo completo (inclui relatorios sem download no periodo)
    'reports_table', (
      SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.downloads DESC, t.lifetime_downloads DESC), '[]'::jsonb) FROM (
        SELECT c.id, c.title, c.report_type, c.distribution, c.access_tiers, c.ticker, c.sector, c.analyst,
               c.published_date,
               coalesce(dp.n, 0) AS downloads, coalesce(dp.u, 0) AS unique_users,
               coalesce(vp.n, 0) AS views, coalesce(vp.u, 0) AS unique_viewers,
               coalesce(dlt.n, 0) AS lifetime_downloads, coalesce(dlt.u, 0) AS lifetime_users,
               coalesce(dlt.first7, 0) AS downloads_first_7d,
               (dlt.last_at AT TIME ZONE 'America/Sao_Paulo')::date AS last_download
        FROM cat c
        LEFT JOIN (SELECT report_id, count(*) n, count(DISTINCT user_id) u FROM dl GROUP BY 1) dp ON dp.report_id = c.id
        LEFT JOIN (SELECT report_id, count(*) n, count(DISTINCT user_id) u FROM vw GROUP BY 1) vp ON vp.report_id = c.id
        LEFT JOIN (
          SELECT d.report_id, count(*) n, count(DISTINCT d.user_id) u, max(d.created_at) last_at,
                 count(*) FILTER (WHERE (d.created_at AT TIME ZONE 'America/Sao_Paulo')::date - c2.published_date BETWEEN 0 AND 7) first7
          FROM dl_all d JOIN cat c2 ON c2.id = d.report_id GROUP BY 1
        ) dlt ON dlt.report_id = c.id
      ) t
    ),
    'reports_top_users', (
      SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.downloads DESC), '[]'::jsonb) FROM (
        SELECT u.email, coalesce(p.plan_now, 'sem_perfil') AS plan, ud.n AS downloads, ud.reports AS distinct_reports,
               (ud.last_at AT TIME ZONE 'America/Sao_Paulo')::date AS last_download,
               (fd.first_at AT TIME ZONE 'America/Sao_Paulo')::date AS first_download
        FROM user_dl ud
        LEFT JOIN auth.users u ON u.id = ud.user_id
        LEFT JOIN prof p ON p.user_id = ud.user_id
        LEFT JOIN first_dl fd ON fd.user_id = ud.user_id
        ORDER BY ud.n DESC LIMIT 30
      ) t
    ),
    'reports_meta', jsonb_build_object('from', p_from, 'to', p_to, 'include_admins', p_include_admins, 'rpc_version', 'bh_reports_v1')
  ) INTO result;

  RETURN result;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_analytics_data_bh_reports_v1(timestamptz, timestamptz, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_analytics_data_bh_reports_v1(timestamptz, timestamptz, boolean) TO service_role;
