-- =====================================================================
-- Security advisor remediation: 7 ERROR-level lints in project BH
--   * auth_users_exposed       (usage_events_clean)
--   * security_definer_view    (6 views)
--
-- Decisões:
--   - usage_events_clean: rebuild SEM auth.users; filtro admin via profiles.is_admin
--   - todas as 6 views: WITH (security_invoker = true)
--   - REVOKE writes pra anon/authenticated em todas
--   - REVOKE SELECT anon em views admin-only
--   - 2 policies novas: analysts (anon SELECT WHERE status='active') +
--                       iacoes_page_views (admin SELECT)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) usage_events_clean — rebuild SEM auth.users + INVOKER + admin-only
--    Substitui filtro por 3 emails hardcoded por NOT EXISTS profiles is_admin.
--    Consumidores: RPCs SECURITY DEFINER (analytics dashboard, rodam como postgres).
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS public.usage_events_clean;

CREATE VIEW public.usage_events_clean
WITH (security_invoker = true) AS
SELECT
  ue.id, ue.user_id, ue.event_name, ue.feature, ue.action, ue.success,
  ue.duration_ms, ue.properties, ue.event_ts, ue.session_id, ue.anon_id,
  ue.plan, ue.subscription_status, ue.billing_period, ue.is_admin,
  ue.is_special_client, ue.account_created_at, ue.route, ue.page,
  ue.section, ue.tab, ue.referrer, ue.landing_page, ue.utm_source,
  ue.utm_medium, ue.utm_campaign, ue.utm_term, ue.utm_content,
  ue.report_id, ue.content_id, ue.company_id, ue.sector_id, ue.analyst_id,
  ue.ticker, ue.portfolio_id, ue.device_type, ue.os, ue.browser,
  ue.locale, ue.timezone, ue.screen, ue.latency_ms, ue.error_code,
  ue.result_count
FROM public.usage_events ue
WHERE NOT EXISTS (
  SELECT 1
  FROM public.profiles p
  WHERE p.user_id = ue.user_id
    AND p.is_admin = true
);

REVOKE ALL ON public.usage_events_clean FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.usage_events_clean FROM authenticated;
GRANT SELECT ON public.usage_events_clean TO authenticated;
GRANT SELECT ON public.usage_events_clean TO service_role;

-- ---------------------------------------------------------------------
-- 2) analyst_public_profiles — INVOKER + nova policy anon SELECT em analysts
--    Caller real: src/pages/AnalystMarketplace.tsx (anon).
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Anon can view active analyst basic info" ON public.analysts;
CREATE POLICY "Anon can view active analyst basic info"
  ON public.analysts FOR SELECT
  TO anon, authenticated
  USING (status = 'active');

ALTER VIEW public.analyst_public_profiles SET (security_invoker = true);
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.analyst_public_profiles FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) v_brapi_dashboard — INVOKER + GRANT explícito na matview base
--    Caller real: app BH Dashboard (anon SELECT).
--    Matview não suporta RLS → GRANT direto formaliza a exposição que
--    já existe efetivamente via view DEFINER atual.
-- ---------------------------------------------------------------------
GRANT SELECT ON public.m_v_brapi_dashboard TO anon, authenticated;

ALTER VIEW public.v_brapi_dashboard SET (security_invoker = true);
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.v_brapi_dashboard FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4) iacoes_page_views_human + iacoes_sessions_enriched — INVOKER + admin-only
--    Caller real: RPCs SECURITY DEFINER do dashboard analytics.
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Admins can read iacoes_page_views" ON public.iacoes_page_views;
CREATE POLICY "Admins can read iacoes_page_views"
  ON public.iacoes_page_views FOR SELECT
  TO authenticated
  USING (is_admin(auth.uid()));

ALTER VIEW public.iacoes_sessions_enriched SET (security_invoker = true);
ALTER VIEW public.iacoes_page_views_human SET (security_invoker = true);

REVOKE ALL ON public.iacoes_sessions_enriched FROM PUBLIC, anon;
REVOKE ALL ON public.iacoes_page_views_human  FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.iacoes_sessions_enriched FROM authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.iacoes_page_views_human FROM authenticated;
GRANT SELECT ON public.iacoes_sessions_enriched TO authenticated;
GRANT SELECT ON public.iacoes_page_views_human  TO authenticated;
GRANT SELECT ON public.iacoes_sessions_enriched TO service_role;
GRANT SELECT ON public.iacoes_page_views_human  TO service_role;

-- ---------------------------------------------------------------------
-- 5) v_gemini_cost_per_user_30d — INVOKER + admin-only
--    RLS admin de usage_events filtra; RPCs SECURITY DEFINER bypassam.
-- ---------------------------------------------------------------------
ALTER VIEW public.v_gemini_cost_per_user_30d SET (security_invoker = true);
REVOKE ALL ON public.v_gemini_cost_per_user_30d FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.v_gemini_cost_per_user_30d FROM authenticated;
GRANT SELECT ON public.v_gemini_cost_per_user_30d TO authenticated;
GRANT SELECT ON public.v_gemini_cost_per_user_30d TO service_role;

-- ---------------------------------------------------------------------
-- 6) PostgREST reload
-- ---------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';
