-- Migration: filter bot sessions from iacoes analytics
-- Date: 2026-04-22
-- Project: brasilhorizonte (dawvgbopyemcayavcatd)
--
-- Cria views iacoes_page_views_human e iacoes_sessions_enriched que filtram
-- sessoes de crawler (padrao Pixel/Chrome/Android mobile com 1 pageview e zero
-- engajamento). Atualiza RPC get_analytics_data() para consumir a view human
-- em todos os blocos de iAcoes. Tabela bruta iacoes_page_views permanece
-- intocada para preservar historico e permitir auditoria via view enriched.
--
-- Regra de deteccao (9 sinais simultaneos por session_id):
--   1) 1 pageview,  2) 0 cta_clicks,  3) sem referrer,  4) sem utm_source,
--   5) sem click_id_source,  6) sem source_hint,
--   7) screen_width = 412,  8) device_type = 'mobile',  9) os = 'Android'

-- ============================================================================
-- View 1: iacoes_page_views_human -- linhas apenas de sessoes humanas
-- ============================================================================

CREATE OR REPLACE VIEW public.iacoes_page_views_human AS
WITH session_flags AS (
  SELECT
    session_id,
    COUNT(*) FILTER (WHERE event_type = 'pageview') = 1
      AND COUNT(*) FILTER (WHERE event_type = 'cta_click') = 0
      AND BOOL_AND(referrer IS NULL OR referrer = '' OR referrer = 'direct')
      AND BOOL_AND(utm_source IS NULL OR utm_source = '')
      AND BOOL_AND(click_id_source IS NULL OR click_id_source = '')
      AND BOOL_AND(source_hint IS NULL OR source_hint = '')
      AND MAX(screen_width) = 412
      AND MAX(device_type) = 'mobile'
      AND MAX(os) = 'Android'
    AS is_bot
  FROM public.iacoes_page_views
  GROUP BY session_id
)
SELECT pv.*
FROM public.iacoes_page_views pv
JOIN session_flags sf USING (session_id)
WHERE sf.is_bot = false;

GRANT SELECT ON public.iacoes_page_views_human TO anon, authenticated, service_role;

-- ============================================================================
-- View 2: iacoes_sessions_enriched -- 1 linha por session com flag is_bot
-- ============================================================================

CREATE OR REPLACE VIEW public.iacoes_sessions_enriched AS
SELECT
  session_id,
  MIN(created_at) AS first_seen,
  MAX(created_at) AS last_seen,
  COUNT(*) FILTER (WHERE event_type = 'pageview') AS pageviews,
  COUNT(*) FILTER (WHERE event_type = 'cta_click') AS cta_clicks,
  MAX(screen_width) AS screen_width,
  MAX(device_type) AS device_type,
  MAX(os) AS os,
  MAX(browser) AS browser,
  BOOL_OR(referrer IS NOT NULL AND referrer <> '' AND referrer <> 'direct') AS has_referrer,
  BOOL_OR(utm_source IS NOT NULL AND utm_source <> '') AS has_utm,
  BOOL_OR(click_id_source IS NOT NULL AND click_id_source <> '') AS has_click_id,
  BOOL_OR(source_hint IS NOT NULL AND source_hint <> '') AS has_source_hint,
  (COUNT(*) FILTER (WHERE event_type = 'pageview') = 1
   AND COUNT(*) FILTER (WHERE event_type = 'cta_click') = 0
   AND BOOL_AND(referrer IS NULL OR referrer = '' OR referrer = 'direct')
   AND BOOL_AND(utm_source IS NULL OR utm_source = '')
   AND BOOL_AND(click_id_source IS NULL OR click_id_source = '')
   AND BOOL_AND(source_hint IS NULL OR source_hint = '')
   AND MAX(screen_width) = 412
   AND MAX(device_type) = 'mobile'
   AND MAX(os) = 'Android')
    AS is_bot
FROM public.iacoes_page_views
GROUP BY session_id;

GRANT SELECT ON public.iacoes_sessions_enriched TO anon, authenticated, service_role;

-- ============================================================================
-- RPC: get_analytics_data() -- substitui iacoes_page_views por iacoes_page_views_human
-- ============================================================================
-- NOTA: corpo copiado de 20260418_bh_revenue_and_new_metrics.sql com substituicao
-- de todas as 20 referencias de public.iacoes_page_views. Demais blocos (auth,
-- storage, usage_events, etc.) permanecem identicos.

CREATE OR REPLACE FUNCTION public.get_analytics_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        'events', (SELECT count(*) FROM public.usage_events WHERE event_ts >= (now() AT TIME ZONE 'America/Sao_Paulo')::date),
        'dau', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_ts >= (now() AT TIME ZONE 'America/Sao_Paulo')::date),
        'signups', (SELECT count(*) FROM public.profiles WHERE created_at >= (now() AT TIME ZONE 'America/Sao_Paulo')::date),
        'logins', (SELECT count(*) FROM public.usage_events WHERE event_name = 'auth_login' AND event_ts >= (now() AT TIME ZONE 'America/Sao_Paulo')::date),
        'paywall_blocks', (SELECT count(*) FROM public.usage_events WHERE event_name = 'paywall_block' AND event_ts >= (now() AT TIME ZONE 'America/Sao_Paulo')::date),
        'payments', (SELECT count(*) FROM public.usage_events WHERE event_name = 'payment_succeeded' AND event_ts >= (now() AT TIME ZONE 'America/Sao_Paulo')::date),
        'cancels', (SELECT count(*) FROM public.usage_events WHERE event_name = 'subscription_cancel' AND event_ts >= (now() AT TIME ZONE 'America/Sao_Paulo')::date),
        'report_downloads', (SELECT count(*) FROM public.report_downloads WHERE created_at >= (now() AT TIME ZONE 'America/Sao_Paulo')::date)
      )
    ),
    'usage_events_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT event_name, count(*) as cnt
        FROM public.usage_events
        GROUP BY event_name
        ORDER BY cnt DESC
        LIMIT 15
      ) t
    ),
    'daily_activity', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               count(*) as events,
               count(DISTINCT user_id) as dau
        FROM public.usage_events
        GROUP BY day
        ORDER BY day ASC
      ) t
    ),
    'feature_usage', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT feature, count(*) as cnt
        FROM public.usage_events
        WHERE feature IS NOT NULL
        GROUP BY feature
        ORDER BY cnt DESC
        LIMIT 20
      ) t
    ),
    'feature_usage_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               feature, count(*) as cnt
        FROM public.usage_events
        WHERE feature IS NOT NULL
        GROUP BY day, feature
        ORDER BY day ASC
      ) t
    ),
    'conversion_funnel', (
      SELECT jsonb_build_object(
        'sessions', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'session_start' AND user_id IS NOT NULL),
        'logins', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'auth_login'),
        'paywall_blocks', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'paywall_block'),
        'checkout_starts', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'checkout_start'),
        'payments', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'payment_succeeded'),
        'cancels', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'subscription_cancel')
      )
    ),
    'device_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT device_type, count(*) as cnt, count(DISTINCT user_id) as unique_users
        FROM public.usage_events WHERE device_type IS NOT NULL
        GROUP BY device_type ORDER BY cnt DESC
      ) t
    ),
    'device_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               device_type, count(*) as cnt, count(DISTINCT user_id) as unique_users
        FROM public.usage_events WHERE device_type IS NOT NULL
        GROUP BY day, device_type ORDER BY day ASC
      ) t
    ),
    'os_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT os, count(*) as cnt FROM public.usage_events
        WHERE os IS NOT NULL GROUP BY os ORDER BY cnt DESC
      ) t
    ),
    'browser_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT browser, count(*) as cnt FROM public.usage_events
        WHERE browser IS NOT NULL GROUP BY browser ORDER BY cnt DESC
      ) t
    ),
    'top_tickers_market', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT ticker, sector, regular_market_price as price,
               market_cap, regular_market_volume,
               regular_market_change_percent, dividend_yield, pl
        FROM public.brapi_quotes
        WHERE market_cap IS NOT NULL
        ORDER BY market_cap DESC NULLS LAST LIMIT 20
      ) t
    ),
    'sector_distribution', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT sector, count(*) as tickers FROM public.brapi_quotes
        WHERE sector IS NOT NULL AND sector != ''
        GROUP BY sector ORDER BY tickers DESC
      ) t
    ),
    'table_sizes', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT relname as name, n_live_tup as rows, pg_total_relation_size(relid) as size_bytes
        FROM pg_stat_user_tables WHERE schemaname = 'public'
        ORDER BY n_live_tup DESC LIMIT 20
      ) t
    ),
    'report_downloads_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               count(*) as downloads
        FROM public.report_downloads GROUP BY day ORDER BY day ASC
      ) t
    ),
    'top_reports_downloaded', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT coalesce(c.ticker, r.title) as ticker,
               r.title, count(*) as downloads, count(DISTINCT rd.user_id) as unique_users
        FROM public.report_downloads rd
        JOIN public.research_reports r ON r.id = rd.report_id
        LEFT JOIN public.companies c ON c.id = r.company_id
        GROUP BY c.ticker, r.title
        ORDER BY downloads DESC LIMIT 15
      ) t
    ),
    'top_tickers_searched', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT ticker, count(*) as cnt FROM public.usage_events
        WHERE ticker IS NOT NULL AND ticker != ''
        GROUP BY ticker ORDER BY cnt DESC LIMIT 15
      ) t
    ),
    'subscribers_overview', (
      SELECT jsonb_build_object(
        'total_profiles', (SELECT count(*) FROM public.profiles),
        'active', (SELECT count(*) FROM public.profiles WHERE subscription_status = 'active'),
        'inactive', (SELECT count(*) FROM public.profiles WHERE subscription_status = 'inactive'),
        'free', (SELECT count(*) FROM public.profiles WHERE subscription_status IS NULL OR subscription_status = 'free'),
        'special_clients', (SELECT count(*) FROM public.profiles WHERE is_special_client = true),
        'churn_rate', (
          SELECT round(
            (SELECT count(*)::numeric FROM public.usage_events WHERE event_name = 'subscription_cancel')
            / nullif(
              (SELECT count(*) FROM public.profiles WHERE subscription_status = 'active')
              + (SELECT count(*) FROM public.usage_events WHERE event_name = 'subscription_cancel'), 0
            ) * 100, 1
          )
        )
      )
    ),
    'subscribers_by_plan', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT coalesce(plan, 'free') as plan, coalesce(subscription_status, 'free') as status,
               billing_period, count(*) as cnt
        FROM public.profiles GROUP BY plan, subscription_status, billing_period ORDER BY cnt DESC
      ) t
    ),
    'signups_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date as day, count(*) as signups
        FROM public.profiles GROUP BY day ORDER BY day ASC
      ) t
    ),
    'subscription_events_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
          count(*) FILTER (WHERE event_name = 'paywall_block') as paywall_blocks,
          count(*) FILTER (WHERE event_name = 'checkout_start') as checkout_starts,
          count(*) FILTER (WHERE event_name = 'checkout_complete') as checkout_completes,
          count(*) FILTER (WHERE event_name = 'payment_succeeded') as payments,
          count(*) FILTER (WHERE event_name = 'subscription_cancel') as cancels,
          count(*) FILTER (WHERE event_name = 'trial_start') as trials
        FROM public.usage_events
        WHERE event_name IN ('paywall_block','checkout_start','checkout_complete','payment_succeeded','subscription_cancel','trial_start')
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'retention_cohorts', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT to_char(p.created_at AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') as cohort,
          count(DISTINCT p.user_id) as cohort_size,
          count(DISTINCT CASE WHEN ue.event_ts BETWEEN p.created_at + interval '7 days' AND p.created_at + interval '14 days' THEN ue.user_id END) as retained_7d,
          count(DISTINCT CASE WHEN ue.event_ts BETWEEN p.created_at + interval '30 days' AND p.created_at + interval '37 days' THEN ue.user_id END) as retained_30d,
          count(DISTINCT CASE WHEN ue.event_ts BETWEEN p.created_at + interval '60 days' AND p.created_at + interval '67 days' THEN ue.user_id END) as retained_60d,
          count(DISTINCT CASE WHEN ue.event_ts BETWEEN p.created_at + interval '90 days' AND p.created_at + interval '97 days' THEN ue.user_id END) as retained_90d
        FROM public.profiles p
        LEFT JOIN public.usage_events ue ON ue.user_id = p.user_id AND ue.event_ts > p.created_at
        GROUP BY cohort ORDER BY cohort ASC
      ) t
    ),
    'top_routes', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT route as page_path, count(*) as views,
               count(DISTINCT user_id) as unique_users, count(DISTINCT session_id) as sessions
        FROM public.usage_events WHERE route IS NOT NULL
        GROUP BY route ORDER BY views DESC LIMIT 10
      ) t
    ),
    'top_landing_pages', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT split_part(landing_page, '?', 1) as landing,
               count(*) as entries, count(DISTINCT user_id) as unique_users
        FROM public.usage_events
        WHERE landing_page IS NOT NULL AND event_name = 'session_start'
        GROUP BY landing ORDER BY entries DESC LIMIT 10
      ) t
    ),
    'referrer_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          CASE
            WHEN referrer IS NULL OR referrer = '' THEN 'Direto'
            WHEN referrer ILIKE '%lovable.dev%' OR referrer ILIKE '%lovableproject.com%' OR referrer ILIKE '%lovable.app%' THEN 'Lovable (Dev)'
            WHEN referrer ILIKE '%localhost%' THEN 'Localhost (Dev)'
            WHEN referrer ILIKE '%iacoes%' THEN 'iAcoes'
            WHEN referrer ILIKE '%brasilhorizonte%' THEN 'Interno'
            WHEN referrer ILIKE '%checkout.stripe.com%' OR referrer ILIKE '%billing.stripe.com%' THEN 'Stripe'
            WHEN referrer ILIKE '%mail.google.com%' OR referrer ILIKE '%outlook%' OR referrer ILIKE '%yahoo.com/mail%' THEN 'Email'
            WHEN referrer ILIKE '%google%' OR referrer ILIKE '%android-app://com.google%' THEN 'Google'
            WHEN referrer ILIKE '%facebook%' OR referrer ILIKE '%fbclid%' THEN 'Facebook'
            WHEN referrer ILIKE '%instagram%' THEN 'Instagram'
            WHEN referrer ILIKE '%twitter%' OR referrer ILIKE '%://x.com%' OR referrer ILIKE '%://t.co/%' THEN 'Twitter/X'
            WHEN referrer ILIKE '%linkedin%' THEN 'LinkedIn'
            WHEN referrer ILIKE '%reddit%' THEN 'Reddit'
            WHEN referrer ILIKE '%youtube%' OR referrer ILIKE '%youtu.be%' THEN 'YouTube'
            WHEN referrer ILIKE '%whatsapp%' THEN 'WhatsApp'
            WHEN referrer ILIKE '%telegram%' OR referrer ILIKE '%t.me%' THEN 'Telegram'
            ELSE 'Outro'
          END as source,
          count(*) as visits, count(DISTINCT user_id) as unique_users
        FROM public.usage_events
        WHERE event_name = 'session_start'
        GROUP BY 1 ORDER BY visits DESC
      ) t
    ),
    'referrer_detail', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT regexp_replace(referrer, '\?.*$', '') as referrer_clean,
               count(*) as visits, count(DISTINCT user_id) as unique_users
        FROM public.usage_events
        WHERE event_name = 'session_start'
          AND referrer IS NOT NULL AND referrer != ''
          AND referrer NOT ILIKE '%brasilhorizonte%'
          AND referrer NOT ILIKE '%localhost%'
          AND referrer NOT ILIKE '%lovable%'
        GROUP BY referrer_clean ORDER BY visits DESC LIMIT 15
      ) t
    ),
    'referrer_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
          CASE
            WHEN referrer IS NULL OR referrer = '' THEN 'Direto'
            WHEN referrer ILIKE '%lovable.dev%' OR referrer ILIKE '%lovableproject.com%' OR referrer ILIKE '%lovable.app%' THEN 'Lovable (Dev)'
            WHEN referrer ILIKE '%localhost%' THEN 'Localhost (Dev)'
            WHEN referrer ILIKE '%iacoes%' THEN 'iAcoes'
            WHEN referrer ILIKE '%brasilhorizonte%' THEN 'Interno'
            WHEN referrer ILIKE '%checkout.stripe.com%' OR referrer ILIKE '%billing.stripe.com%' THEN 'Stripe'
            WHEN referrer ILIKE '%mail.google.com%' OR referrer ILIKE '%outlook%' OR referrer ILIKE '%yahoo.com/mail%' THEN 'Email'
            WHEN referrer ILIKE '%google%' OR referrer ILIKE '%android-app://com.google%' THEN 'Google'
            WHEN referrer ILIKE '%facebook%' OR referrer ILIKE '%fbclid%' THEN 'Facebook'
            WHEN referrer ILIKE '%instagram%' THEN 'Instagram'
            WHEN referrer ILIKE '%twitter%' OR referrer ILIKE '%://x.com%' OR referrer ILIKE '%://t.co/%' THEN 'Twitter/X'
            WHEN referrer ILIKE '%linkedin%' THEN 'LinkedIn'
            WHEN referrer ILIKE '%reddit%' THEN 'Reddit'
            WHEN referrer ILIKE '%youtube%' OR referrer ILIKE '%youtu.be%' THEN 'YouTube'
            WHEN referrer ILIKE '%whatsapp%' THEN 'WhatsApp'
            WHEN referrer ILIKE '%telegram%' OR referrer ILIKE '%t.me%' THEN 'Telegram'
            ELSE 'Outro'
          END as source,
          count(*) as visits, count(DISTINCT user_id) as unique_users
        FROM public.usage_events
        WHERE event_name = 'session_start'
        GROUP BY 1, 2 ORDER BY day ASC
      ) t
    ),
    'screen_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT screen, count(*) as cnt FROM public.usage_events
        WHERE screen IS NOT NULL GROUP BY screen ORDER BY cnt DESC LIMIT 10
      ) t
    ),
    'session_metrics_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH session_stats AS (
          SELECT session_id,
                 date_trunc('day', min(event_ts) AT TIME ZONE 'America/Sao_Paulo')::date as day,
                 count(*) as events,
                 extract(epoch FROM max(event_ts) - min(event_ts)) as duration_secs
          FROM public.usage_events WHERE session_id IS NOT NULL
          GROUP BY session_id HAVING count(*) > 1
        )
        SELECT day, round(avg(events)::numeric, 1) as avg_events_per_session,
               round((avg(duration_secs) / 60)::numeric, 1) as avg_duration_min,
               round((percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_secs) / 60)::numeric, 1) as median_duration_min,
               count(*) as total_sessions
        FROM session_stats GROUP BY day ORDER BY day ASC
      ) t
    ),
    'stickiness', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH user_days AS (
          SELECT DISTINCT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day, user_id
          FROM public.usage_events WHERE user_id IS NOT NULL
        ),
        daily_counts AS (SELECT day, count(*) as dau FROM user_days GROUP BY day),
        weekly_counts AS (
          SELECT d.day, count(DISTINCT ud.user_id) as wau
          FROM (SELECT DISTINCT day FROM user_days) d
          JOIN user_days ud ON ud.day BETWEEN d.day - 6 AND d.day GROUP BY d.day
        ),
        monthly_counts AS (
          SELECT d.day, count(DISTINCT ud.user_id) as mau
          FROM (SELECT DISTINCT day FROM user_days) d
          JOIN user_days ud ON ud.day BETWEEN d.day - 29 AND d.day GROUP BY d.day
        )
        SELECT dc.day, dc.dau, wc.wau, mc.mau,
               round(dc.dau::numeric / nullif(wc.wau, 0) * 100, 1) as dau_wau_pct,
               round(dc.dau::numeric / nullif(mc.mau, 0) * 100, 1) as dau_mau_pct
        FROM daily_counts dc
        JOIN weekly_counts wc ON wc.day = dc.day
        JOIN monthly_counts mc ON mc.day = dc.day
        ORDER BY dc.day ASC
      ) t
    ),
    'new_vs_returning_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH user_first_day AS (
          SELECT user_id, min(date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date) as first_day
          FROM public.usage_events WHERE user_id IS NOT NULL GROUP BY user_id
        ),
        daily_users AS (
          SELECT DISTINCT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day, user_id
          FROM public.usage_events WHERE user_id IS NOT NULL
        )
        SELECT du.day,
               count(*) FILTER (WHERE du.day = uf.first_day) as new_users,
               count(*) FILTER (WHERE du.day > uf.first_day) as returning_users
        FROM daily_users du JOIN user_first_day uf ON uf.user_id = du.user_id
        GROUP BY du.day ORDER BY du.day ASC
      ) t
    ),
    'activity_heatmap', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT extract(dow FROM event_ts AT TIME ZONE 'America/Sao_Paulo')::int as dow,
               extract(hour FROM event_ts AT TIME ZONE 'America/Sao_Paulo')::int as hour,
               count(*) as events
        FROM public.usage_events GROUP BY dow, hour ORDER BY dow, hour
      ) t
    ),
    'time_to_convert', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH first_payment AS (
          SELECT user_id, min(event_ts) as paid_at FROM public.usage_events
          WHERE event_name = 'payment_succeeded' GROUP BY user_id
        )
        SELECT
          CASE
            WHEN extract(epoch FROM fp.paid_at - p.created_at) / 86400 <= 1 THEN '< 1 dia'
            WHEN extract(epoch FROM fp.paid_at - p.created_at) / 86400 <= 3 THEN '1-3 dias'
            WHEN extract(epoch FROM fp.paid_at - p.created_at) / 86400 <= 7 THEN '3-7 dias'
            WHEN extract(epoch FROM fp.paid_at - p.created_at) / 86400 <= 14 THEN '7-14 dias'
            WHEN extract(epoch FROM fp.paid_at - p.created_at) / 86400 <= 30 THEN '14-30 dias'
            ELSE '30+ dias'
          END as bucket,
          count(*) as conversions,
          round(avg(extract(epoch FROM fp.paid_at - p.created_at) / 86400)::numeric, 1) as avg_days
        FROM first_payment fp JOIN public.profiles p ON p.user_id = fp.user_id
        GROUP BY bucket ORDER BY min(extract(epoch FROM fp.paid_at - p.created_at))
      ) t
    ),
    'feature_paywall', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT feature, count(*) as paywall_hits FROM public.usage_events
        WHERE session_id IN (
          SELECT DISTINCT session_id FROM public.usage_events
          WHERE event_name = 'paywall_block' AND session_id IS NOT NULL
        ) AND feature IS NOT NULL AND event_name = 'feature_open'
        GROUP BY feature ORDER BY paywall_hits DESC LIMIT 10
      ) t
    ),
    'mrr_estimate', (
      SELECT jsonb_build_object(
        'monthly_subs', (SELECT count(*) FROM public.profiles WHERE subscription_status = 'active' AND billing_period = 'monthly'),
        'yearly_subs', (SELECT count(*) FROM public.profiles WHERE subscription_status = 'active' AND billing_period = 'yearly'),
        'lifetime_subs', (SELECT count(*) FROM public.profiles WHERE subscription_status = 'active' AND billing_period = 'lifetime'),
        'total_payments', (SELECT count(*) FROM public.usage_events WHERE event_name = 'payment_succeeded'),
        'total_paying_users', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'payment_succeeded'),
        'avg_subscription_age_days', (
          SELECT round(avg(extract(epoch FROM now() - created_at) / 86400)::numeric, 0)
          FROM public.profiles WHERE subscription_status = 'active'
        )
      )
    ),
    'subscription_age', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          CASE
            WHEN extract(epoch FROM now() - created_at) / 86400 <= 7 THEN '< 1 sem'
            WHEN extract(epoch FROM now() - created_at) / 86400 <= 30 THEN '1-4 sem'
            WHEN extract(epoch FROM now() - created_at) / 86400 <= 90 THEN '1-3 meses'
            WHEN extract(epoch FROM now() - created_at) / 86400 <= 180 THEN '3-6 meses'
            ELSE '6+ meses'
          END as age_bucket,
          count(*) as users,
          count(*) FILTER (WHERE subscription_status = 'active') as active,
          count(*) FILTER (WHERE subscription_status != 'active' OR subscription_status IS NULL) as churned
        FROM public.profiles WHERE created_at IS NOT NULL
        GROUP BY age_bucket ORDER BY min(extract(epoch FROM now() - created_at))
      ) t
    ),
    'section_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               section, count(*) as cnt
        FROM public.usage_events WHERE section IS NOT NULL
        GROUP BY day, section ORDER BY day ASC
      ) t
    ),
    -- ===== iAcoes Page Views =====
    'iacoes_overview', (
      SELECT jsonb_build_object(
        'total_views', (SELECT count(*) FROM public.iacoes_page_views_human WHERE event_type = 'pageview' OR event_type IS NULL),
        'total_sessions', (SELECT count(DISTINCT session_id) FROM public.iacoes_page_views_human),
        'total_pages', (SELECT count(DISTINCT page_path) FROM public.iacoes_page_views_human),
        'views_today', (SELECT count(*) FROM public.iacoes_page_views_human WHERE created_at >= (now() AT TIME ZONE 'America/Sao_Paulo')::date AND (event_type = 'pageview' OR event_type IS NULL)),
        'sessions_today', (SELECT count(DISTINCT session_id) FROM public.iacoes_page_views_human WHERE created_at >= (now() AT TIME ZONE 'America/Sao_Paulo')::date)
      )
    ),
    'iacoes_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               count(*) FILTER (WHERE event_type = 'pageview' OR event_type IS NULL) as views,
               count(DISTINCT session_id) as sessions,
               count(*) FILTER (WHERE event_type = 'cta_click') as cta_clicks
        FROM public.iacoes_page_views_human
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'iacoes_top_pages', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT page_path,
          count(*) FILTER (WHERE event_type = 'pageview' OR event_type IS NULL) as views,
          count(DISTINCT session_id) as sessions,
          count(*) FILTER (WHERE event_type = 'cta_click') as cta_clicks
        FROM public.iacoes_page_views_human
        GROUP BY page_path ORDER BY views DESC LIMIT 20
      ) t
    ),
    'iacoes_referrers', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          CASE
            WHEN referrer ILIKE '%google%' OR referrer ILIKE '%android-app://com.google%' THEN 'Google'
            WHEN referrer ILIKE '%bing%' THEN 'Bing'
            WHEN referrer ILIKE '%yahoo%' THEN 'Yahoo'
            WHEN referrer ILIKE '%brasilhorizonte%' OR referrer ILIKE '%iacoes%' THEN 'Interno'
            WHEN referrer ILIKE '%facebook%' OR referrer ILIKE '%fbclid%' THEN 'Facebook'
            WHEN referrer ILIKE '%instagram%' THEN 'Instagram'
            WHEN referrer ILIKE '%twitter%' OR referrer ILIKE '%://x.com%' OR referrer ILIKE '%://t.co/%' THEN 'Twitter/X'
            WHEN referrer ILIKE '%linkedin%' THEN 'LinkedIn'
            WHEN referrer ILIKE '%reddit%' THEN 'Reddit'
            WHEN referrer ILIKE '%youtube%' OR referrer ILIKE '%youtu.be%' THEN 'YouTube'
            WHEN referrer ILIKE '%whatsapp%' THEN 'WhatsApp'
            WHEN referrer ILIKE '%telegram%' OR referrer ILIKE '%t.me%' THEN 'Telegram'
            WHEN click_id_source = 'facebook' THEN 'Facebook (ads)'
            WHEN click_id_source = 'google_ads' THEN 'Google (ads)'
            WHEN click_id_source = 'tiktok' THEN 'TikTok (ads)'
            WHEN click_id_source = 'linkedin' THEN 'LinkedIn (ads)'
            WHEN click_id_source = 'twitter' THEN 'Twitter/X (ads)'
            WHEN click_id_source = 'microsoft_ads' THEN 'Bing (ads)'
            WHEN source_hint = 'facebook' THEN 'Facebook (app)'
            WHEN source_hint = 'instagram' THEN 'Instagram (app)'
            WHEN source_hint = 'linkedin' THEN 'LinkedIn (app)'
            WHEN source_hint = 'whatsapp' THEN 'WhatsApp (app)'
            WHEN source_hint = 'telegram' THEN 'Telegram (app)'
            WHEN source_hint = 'twitter' THEN 'Twitter/X (app)'
            WHEN referrer IS NOT NULL AND referrer != '' THEN 'Outro'
            ELSE 'Direto'
          END as source,
          count(*) FILTER (WHERE event_type = 'pageview' OR event_type IS NULL) as views,
          count(DISTINCT session_id) as sessions
        FROM public.iacoes_page_views_human
        GROUP BY 1 ORDER BY views DESC
      ) t
    ),
    'iacoes_referrer_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
          CASE
            WHEN referrer ILIKE '%google%' OR referrer ILIKE '%android-app://com.google%' THEN 'Google'
            WHEN referrer ILIKE '%bing%' THEN 'Bing'
            WHEN referrer ILIKE '%yahoo%' THEN 'Yahoo'
            WHEN referrer ILIKE '%brasilhorizonte%' OR referrer ILIKE '%iacoes%' THEN 'Interno'
            WHEN referrer ILIKE '%facebook%' OR referrer ILIKE '%fbclid%' THEN 'Facebook'
            WHEN referrer ILIKE '%instagram%' THEN 'Instagram'
            WHEN referrer ILIKE '%twitter%' OR referrer ILIKE '%://x.com%' OR referrer ILIKE '%://t.co/%' THEN 'Twitter/X'
            WHEN referrer ILIKE '%linkedin%' THEN 'LinkedIn'
            WHEN referrer ILIKE '%reddit%' THEN 'Reddit'
            WHEN referrer ILIKE '%youtube%' OR referrer ILIKE '%youtu.be%' THEN 'YouTube'
            WHEN referrer ILIKE '%whatsapp%' THEN 'WhatsApp'
            WHEN referrer ILIKE '%telegram%' OR referrer ILIKE '%t.me%' THEN 'Telegram'
            WHEN click_id_source = 'facebook' THEN 'Facebook (ads)'
            WHEN click_id_source = 'google_ads' THEN 'Google (ads)'
            WHEN click_id_source = 'tiktok' THEN 'TikTok (ads)'
            WHEN click_id_source = 'linkedin' THEN 'LinkedIn (ads)'
            WHEN click_id_source = 'twitter' THEN 'Twitter/X (ads)'
            WHEN click_id_source = 'microsoft_ads' THEN 'Bing (ads)'
            WHEN source_hint = 'facebook' THEN 'Facebook (app)'
            WHEN source_hint = 'instagram' THEN 'Instagram (app)'
            WHEN source_hint = 'linkedin' THEN 'LinkedIn (app)'
            WHEN source_hint = 'whatsapp' THEN 'WhatsApp (app)'
            WHEN source_hint = 'telegram' THEN 'Telegram (app)'
            WHEN source_hint = 'twitter' THEN 'Twitter/X (app)'
            WHEN referrer IS NOT NULL AND referrer != '' THEN 'Outro'
            ELSE 'Direto'
          END as source,
          count(*) FILTER (WHERE event_type = 'pageview' OR event_type IS NULL) as views,
          count(DISTINCT session_id) as sessions
        FROM public.iacoes_page_views_human
        GROUP BY 1, 2 ORDER BY day ASC
      ) t
    ),
    'iacoes_devices', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT device_type, count(*) as views, count(DISTINCT session_id) as sessions
        FROM public.iacoes_page_views_human WHERE device_type IS NOT NULL
        GROUP BY device_type ORDER BY views DESC
      ) t
    ),
    'iacoes_browsers', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT browser, count(*) as views
        FROM public.iacoes_page_views_human WHERE browser IS NOT NULL
        GROUP BY browser ORDER BY views DESC
      ) t
    ),
    'iacoes_os', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT os, count(*) as views
        FROM public.iacoes_page_views_human WHERE os IS NOT NULL
        GROUP BY os ORDER BY views DESC
      ) t
    ),
    'iacoes_utm', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT utm_source, utm_medium, utm_campaign, count(*) as views, count(DISTINCT session_id) as sessions
        FROM public.iacoes_page_views_human
        WHERE utm_source IS NOT NULL
        GROUP BY utm_source, utm_medium, utm_campaign ORDER BY views DESC LIMIT 20
      ) t
    ),
    'iacoes_source_detection', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          coalesce(source_hint, 'nenhum') as source_hint,
          coalesce(click_id_source, 'nenhum') as click_id_source,
          CASE
            WHEN referrer IS NULL OR referrer = '' THEN 'vazio'
            ELSE 'presente'
          END as referrer_status,
          count(*) as total
        FROM public.iacoes_page_views_human
        GROUP BY 1, 2, 3
        ORDER BY total DESC
      ) t
    )
  ) INTO result;

  -- iAcoes -> BH Conversion Analysis
  result := result || jsonb_build_object(
    'iacoes_conversion_funnel', (
      SELECT jsonb_build_object(
        'iacoes_views', (SELECT count(*) FROM public.iacoes_page_views_human WHERE event_type = 'pageview' OR event_type IS NULL),
        'cta_clicks', (SELECT count(*) FROM public.iacoes_page_views_human WHERE event_type = 'cta_click'),
        'bh_sessions', (SELECT count(*) FROM public.usage_events WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%'),
        'bh_unique_users', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%' AND user_id IS NOT NULL),
        'bh_logins', (SELECT count(*) FROM public.usage_events WHERE event_name = 'auth_login' AND session_id IN (SELECT DISTINCT session_id FROM public.usage_events WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%')),
        'bh_paywall', (SELECT count(*) FROM public.usage_events WHERE event_name = 'paywall_block' AND session_id IN (SELECT DISTINCT session_id FROM public.usage_events WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%')),
        'bh_payments', (SELECT count(*) FROM public.usage_events WHERE event_name = 'payment_succeeded' AND session_id IN (SELECT DISTINCT session_id FROM public.usage_events WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%'))
      )
    ),
    'iacoes_conversion_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH iacoes_sessions AS (
          SELECT DISTINCT session_id FROM public.usage_events
          WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%'
        )
        SELECT date_trunc('day', ue.event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
          count(*) FILTER (WHERE ue.event_name = 'session_start' AND ue.referrer ILIKE '%iacoes%') as sessions,
          count(DISTINCT ue.user_id) FILTER (WHERE ue.event_name = 'session_start' AND ue.referrer ILIKE '%iacoes%') as unique_users,
          count(*) FILTER (WHERE ue.event_name = 'auth_login') as logins,
          count(*) FILTER (WHERE ue.event_name = 'paywall_block') as paywall,
          count(*) FILTER (WHERE ue.event_name = 'checkout_start') as checkout,
          count(*) FILTER (WHERE ue.event_name = 'payment_succeeded') as payments
        FROM public.usage_events ue
        WHERE ue.session_id IN (SELECT session_id FROM iacoes_sessions)
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'iacoes_converting_tickers', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          CASE
            WHEN referrer ~ '/([A-Z]{4}[0-9]{1,2})' THEN (regexp_match(referrer, '/([A-Z]{4}[0-9]{1,2})'))[1]
            WHEN referrer ~ 'iacoes\.com\.br/?$' OR referrer ~ 'iacoes\.brasilhorizonte\.com\.br/?$' THEN 'Home'
            ELSE 'Outro'
          END as ticker,
          count(*) as sessions,
          count(DISTINCT user_id) as unique_users,
          count(*) FILTER (WHERE session_id IN (
            SELECT DISTINCT session_id FROM public.usage_events WHERE event_name = 'auth_login'
          )) as led_to_login,
          count(*) FILTER (WHERE session_id IN (
            SELECT DISTINCT session_id FROM public.usage_events WHERE event_name = 'paywall_block'
          )) as led_to_paywall
        FROM public.usage_events
        WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%'
        GROUP BY 1 ORDER BY sessions DESC LIMIT 20
      ) t
    ),
    'iacoes_vs_other_conversion', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH source_sessions AS (
          SELECT session_id,
            CASE
                   WHEN referrer ILIKE '%iacoes%' THEN 'iAcoes'
                   WHEN referrer ILIKE '%lovable.dev%' OR referrer ILIKE '%lovableproject.com%' OR referrer ILIKE '%lovable.app%' THEN 'Lovable (Dev)'
                   WHEN referrer ILIKE '%localhost%' THEN 'Localhost (Dev)'
                   WHEN referrer ILIKE '%brasilhorizonte%' THEN 'App BH'
                   WHEN referrer ILIKE '%checkout.stripe.com%' OR referrer ILIKE '%billing.stripe.com%' THEN 'Stripe'
                   WHEN referrer ILIKE '%google%' OR referrer ILIKE '%android-app://com.google%' THEN 'Google'
                   WHEN referrer ILIKE '%facebook%' OR referrer ILIKE '%fbclid%' THEN 'Facebook'
                   WHEN referrer ILIKE '%instagram%' THEN 'Instagram'
                   WHEN referrer ILIKE '%twitter%' OR referrer ILIKE '%://x.com%' OR referrer ILIKE '%://t.co/%' THEN 'Twitter/X'
                   WHEN referrer ILIKE '%linkedin%' THEN 'LinkedIn'
                   WHEN referrer ILIKE '%whatsapp%' THEN 'WhatsApp'
                   WHEN referrer ILIKE '%telegram%' OR referrer ILIKE '%t.me%' THEN 'Telegram'
                   WHEN referrer ILIKE '%youtube%' OR referrer ILIKE '%youtu.be%' THEN 'YouTube'
                   WHEN referrer ILIKE '%reddit%' THEN 'Reddit'
                   WHEN referrer IS NULL OR referrer = '' THEN 'Direto'
                   ELSE split_part(replace(replace(referrer, 'https://', ''), 'http://', ''), '/', 1)
                 END as source
          FROM public.usage_events WHERE event_name = 'session_start'
        )
        SELECT ss.source,
          count(DISTINCT ss.session_id) as sessions,
          count(DISTINCT ue_login.session_id) as logins,
          count(DISTINCT ue_pay.session_id) as paywall,
          round(count(DISTINCT ue_login.session_id)::numeric / nullif(count(DISTINCT ss.session_id), 0) * 100, 1) as login_rate,
          round(count(DISTINCT ue_pay.session_id)::numeric / nullif(count(DISTINCT ss.session_id), 0) * 100, 1) as paywall_rate
        FROM source_sessions ss
        LEFT JOIN public.usage_events ue_login ON ue_login.session_id = ss.session_id AND ue_login.event_name = 'auth_login'
        LEFT JOIN public.usage_events ue_pay ON ue_pay.session_id = ss.session_id AND ue_pay.event_name = 'paywall_block'
        GROUP BY ss.source ORDER BY sessions DESC
      ) t
    )
  );

  -- ===== NEW METRICS =====
  result := result || jsonb_build_object(
    'ticker_by_feature', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT feature, ticker, count(*) as cnt, count(DISTINCT user_id) as unique_users
        FROM public.usage_events
        WHERE ticker IS NOT NULL AND ticker != '' AND feature IS NOT NULL
        GROUP BY feature, ticker ORDER BY feature, cnt DESC
      ) t
    ),
    'ticker_trend_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH top_tickers AS (
          SELECT ticker FROM public.usage_events
          WHERE ticker IS NOT NULL AND ticker != ''
          GROUP BY ticker ORDER BY count(*) DESC LIMIT 10
        )
        SELECT date_trunc('day', ue.event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               ue.ticker, count(*) as cnt
        FROM public.usage_events ue
        JOIN top_tickers tt ON tt.ticker = ue.ticker
        GROUP BY day, ue.ticker ORDER BY day ASC
      ) t
    ),
    'feature_usage_trend', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               feature, count(*) as cnt, count(DISTINCT user_id) as unique_users,
               count(DISTINCT ticker) as unique_tickers
        FROM public.usage_events
        WHERE feature IS NOT NULL AND ticker IS NOT NULL AND ticker != ''
        GROUP BY day, feature ORDER BY day ASC
      ) t
    ),
    'user_inactivity', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT ue.user_id, coalesce(u.email, ue.user_id::text) as email,
               max(ue.event_ts) as last_event_ts,
               extract(day FROM now() - max(ue.event_ts))::int as days_inactive,
               count(*) as total_events
        FROM public.usage_events ue
        LEFT JOIN auth.users u ON u.id = ue.user_id
        WHERE ue.user_id IS NOT NULL
        GROUP BY ue.user_id, u.email
        ORDER BY days_inactive DESC
      ) t
    ),
    'inactivity_distribution', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH user_last AS (
          SELECT user_id, max(event_ts) as last_ts
          FROM public.usage_events WHERE user_id IS NOT NULL GROUP BY user_id
        )
        SELECT
          CASE
            WHEN extract(day FROM now() - last_ts) < 1 THEN 'Ativo hoje'
            WHEN extract(day FROM now() - last_ts) <= 3 THEN '1-3 dias'
            WHEN extract(day FROM now() - last_ts) <= 7 THEN '4-7 dias'
            WHEN extract(day FROM now() - last_ts) <= 14 THEN '8-14 dias'
            WHEN extract(day FROM now() - last_ts) <= 30 THEN '15-30 dias'
            ELSE '30+ dias'
          END as bucket,
          count(*) as users
        FROM user_last
        GROUP BY bucket ORDER BY min(extract(day FROM now() - last_ts))
      ) t
    ),
    'user_feature_breadth', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH user_features AS (
          SELECT user_id, count(DISTINCT feature) as feature_count
          FROM public.usage_events
          WHERE user_id IS NOT NULL AND feature IS NOT NULL
          GROUP BY user_id
        )
        SELECT
          CASE
            WHEN feature_count = 1 THEN '1 ferramenta'
            WHEN feature_count = 2 THEN '2 ferramentas'
            WHEN feature_count = 3 THEN '3 ferramentas'
            ELSE '4+ ferramentas'
          END as breadth,
          count(*) as users
        FROM user_features
        GROUP BY breadth ORDER BY min(feature_count)
      ) t
    )
  );

  -- Ticker Ranking & User Ticker Usage
  result := result || jsonb_build_object(
    'ticker_ranking', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT ticker, COUNT(*) as cnt
        FROM public.usage_events
        WHERE ticker IS NOT NULL AND ticker != ''
        GROUP BY ticker ORDER BY cnt DESC LIMIT 20
      ) t
    ),
    'user_ticker_usage', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          e.user_id,
          coalesce(u.email, e.user_id::text) as email,
          COUNT(*) as total_queries,
          COUNT(DISTINCT e.ticker) as unique_tickers,
          MODE() WITHIN GROUP (ORDER BY e.ticker) as top_ticker,
          MODE() WITHIN GROUP (ORDER BY e.feature) as top_feature,
          MAX(e.event_ts) as last_activity
        FROM public.usage_events e
        LEFT JOIN auth.users u ON u.id = e.user_id
        WHERE e.ticker IS NOT NULL AND e.ticker != '' AND e.user_id IS NOT NULL
        GROUP BY e.user_id, u.email
        ORDER BY total_queries DESC
        LIMIT 100
      ) t
    ),
    'user_ticker_detail', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          e.user_id,
          e.ticker,
          e.feature,
          COUNT(*) as cnt
        FROM public.usage_events e
        WHERE e.ticker IS NOT NULL AND e.ticker != '' AND e.user_id IS NOT NULL AND e.feature IS NOT NULL
        GROUP BY e.user_id, e.ticker, e.feature
        ORDER BY cnt DESC
      ) t
    ),
    'login_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               count(*) as logins,
               count(DISTINCT user_id) as unique_users
        FROM public.usage_events
        WHERE event_name = 'auth_login'
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'monthly_active_users', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('month', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as month,
               count(DISTINCT user_id) as unique_users
        FROM public.usage_events
        WHERE user_id IS NOT NULL
        GROUP BY month ORDER BY month ASC
      ) t
    ),
    'watchlist_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH portfolio_tickers AS (
          SELECT user_id,
                 jsonb_array_elements(
                   jsonb_array_elements(portfolios)->'assets'
                 )->>'ticker' as ticker
          FROM public.user_portfolios
          WHERE portfolios IS NOT NULL
        )
        SELECT ticker, count(DISTINCT user_id) as cnt
        FROM portfolio_tickers
        WHERE ticker IS NOT NULL AND ticker != ''
        GROUP BY ticker ORDER BY cnt DESC LIMIT 20
      ) t
    ),
    'revenue_by_plan', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT plan, billing_period, count(*) as subscribers,
               CASE
                 WHEN plan = 'essencial' AND billing_period = 'monthly' THEN count(*) * 29.90
                 WHEN plan = 'essencial' AND billing_period = 'yearly' THEN count(*) * 239.90 / 12
                 WHEN plan = 'fundamentalista' AND billing_period = 'monthly' THEN count(*) * 49.90
                 WHEN plan = 'fundamentalista' AND billing_period = 'yearly' THEN count(*) * 449.90 / 12
                 WHEN plan = 'ianalista' AND billing_period = 'monthly' THEN count(*) * 39.90
                 WHEN plan = 'ianalista' AND billing_period = 'yearly' THEN count(*) * 399.00 / 12
                 WHEN plan = 'ialocador' AND billing_period = 'monthly' THEN count(*) * 59.90
                 WHEN plan = 'ialocador' AND billing_period = 'yearly' THEN count(*) * 599.00 / 12
                 WHEN plan = 'valor' AND billing_period = 'monthly' THEN count(*) * 149.90
                 WHEN plan = 'valor' AND billing_period = 'yearly' THEN count(*) * 1349.90 / 12
                 ELSE 0
               END as mrr_estimate
        FROM public.profiles
        WHERE subscription_status = 'active' AND plan IS NOT NULL AND plan != 'free'
        GROUP BY plan, billing_period
        ORDER BY mrr_estimate DESC
      ) t
    )
  );

  -- ===== iAcoes daily breakdowns for date filtering =====
  result := result || jsonb_build_object(
    'iacoes_pages_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               page_path,
               count(*) FILTER (WHERE event_type = 'pageview' OR event_type IS NULL) as views,
               count(DISTINCT session_id) as sessions,
               count(*) FILTER (WHERE event_type = 'cta_click') as cta_clicks
        FROM public.iacoes_page_views_human
        GROUP BY day, page_path
        ORDER BY day ASC
      ) t
    ),
    'iacoes_converting_tickers_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH iacoes_sess AS (
          SELECT session_id,
                 date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
                 CASE
                   WHEN referrer ~ '/([A-Z]{4}[0-9]{1,2})' THEN (regexp_match(referrer, '/([A-Z]{4}[0-9]{1,2})'))[1]
                   WHEN referrer ~ 'iacoes\.com\.br/?$' OR referrer ~ 'iacoes\.brasilhorizonte\.com\.br/?$' THEN 'Home'
                   ELSE 'Outro'
                 END as ticker,
                 user_id
          FROM public.usage_events
          WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%'
        )
        SELECT s.day, s.ticker,
               count(DISTINCT s.session_id) as sessions,
               count(DISTINCT s.user_id) as unique_users,
               count(DISTINCT CASE WHEN ue_l.session_id IS NOT NULL THEN s.session_id END) as led_to_login,
               count(DISTINCT CASE WHEN ue_p.session_id IS NOT NULL THEN s.session_id END) as led_to_paywall
        FROM iacoes_sess s
        LEFT JOIN public.usage_events ue_l ON ue_l.session_id = s.session_id AND ue_l.event_name = 'auth_login'
        LEFT JOIN public.usage_events ue_p ON ue_p.session_id = s.session_id AND ue_p.event_name = 'paywall_block'
        WHERE s.ticker IS NOT NULL AND s.ticker != ''
        GROUP BY s.day, s.ticker
        ORDER BY s.day ASC
      ) t
    )
  );


  -- ===== CTA Breakdown by ID =====
  result := result || jsonb_build_object(
    'iacoes_cta_breakdown', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT coalesce(cta_id, 'sem_id') as cta_id,
               count(*) as clicks,
               count(DISTINCT session_id) as unique_sessions
        FROM public.iacoes_page_views_human
        WHERE event_type = 'cta_click'
        GROUP BY cta_id
        ORDER BY clicks DESC
      ) t
    ),
    'iacoes_cta_by_page', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT coalesce(cta_id, 'sem_id') as cta_id,
               page_path,
               count(*) as clicks
        FROM public.iacoes_page_views_human
        WHERE event_type = 'cta_click'
        GROUP BY cta_id, page_path
        ORDER BY clicks DESC LIMIT 50
      ) t
    ),
    'iacoes_cta_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               coalesce(cta_id, 'sem_id') as cta_id,
               count(*) as clicks
        FROM public.iacoes_page_views_human
        WHERE event_type = 'cta_click'
        GROUP BY day, cta_id
        ORDER BY day ASC
      ) t
    )
  );


  -- ===== Subscriber time series + trial funnel (Sally plan) =====
  result := result || jsonb_build_object(
    'active_subscribers_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH first_payment AS (
          SELECT user_id, min(event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS first_paid_day
          FROM public.usage_events WHERE event_name = 'payment_succeeded' AND user_id IS NOT NULL GROUP BY user_id
        ),
        last_cancel AS (
          SELECT user_id, max(event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS last_cancel_day
          FROM public.usage_events WHERE event_name = 'subscription_cancel' AND user_id IS NOT NULL GROUP BY user_id
        ),
        day_series AS (
          SELECT generate_series(
            coalesce((SELECT min(first_paid_day) FROM first_payment), CURRENT_DATE - interval '90 days')::date,
            CURRENT_DATE,
            '1 day'::interval
          )::date AS day
        )
        SELECT d.day,
          count(DISTINCT fp.user_id) FILTER (
            WHERE fp.first_paid_day <= d.day
              AND (lc.last_cancel_day IS NULL OR lc.last_cancel_day > d.day)
          ) AS active_subs
        FROM day_series d
        LEFT JOIN first_payment fp ON fp.first_paid_day <= d.day
        LEFT JOIN last_cancel lc ON lc.user_id = fp.user_id
        GROUP BY d.day ORDER BY d.day ASC
      ) t
    ),
    'new_subscribers_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH first_payment AS (
          SELECT user_id, min(event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS first_paid_day
          FROM public.usage_events WHERE event_name = 'payment_succeeded' AND user_id IS NOT NULL GROUP BY user_id
        )
        SELECT first_paid_day AS day, count(*) AS new_subs
        FROM first_payment GROUP BY first_paid_day ORDER BY first_paid_day ASC
      ) t
    ),
    'trial_funnel_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH trials AS (
          SELECT user_id, min(event_ts) AS trial_ts
          FROM public.usage_events WHERE event_name = 'trial_start' AND user_id IS NOT NULL GROUP BY user_id
        ),
        first_payment AS (
          SELECT user_id, min(event_ts) AS first_paid_ts
          FROM public.usage_events WHERE event_name = 'payment_succeeded' AND user_id IS NOT NULL GROUP BY user_id
        )
        SELECT (t.trial_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               count(*) AS trials_started,
               count(*) FILTER (WHERE fp.first_paid_ts IS NOT NULL AND fp.first_paid_ts <= t.trial_ts + interval '14 days') AS trials_converted,
               count(*) FILTER (WHERE (fp.first_paid_ts IS NULL OR fp.first_paid_ts > t.trial_ts + interval '14 days') AND t.trial_ts + interval '14 days' < now()) AS trials_expired
        FROM trials t LEFT JOIN first_payment fp ON fp.user_id = t.user_id
        GROUP BY day ORDER BY day ASC
      ) t
    )
  );

  -- ===== Portfolio + content/cvm filter activity =====
  result := result || jsonb_build_object(
    'portfolio_activity_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
          count(*) FILTER (WHERE event_name = 'portfolio_add_asset') AS adds,
          count(*) FILTER (WHERE event_name = 'portfolio_remove_asset') AS removes,
          count(*) FILTER (WHERE event_name = 'portfolio_save') AS saves,
          count(*) FILTER (WHERE event_name = 'portfolio_load') AS loads,
          count(*) FILTER (WHERE event_name = 'content_filter_portfolio_apply') AS content_filters,
          count(*) FILTER (WHERE event_name = 'cvm_filter_portfolio_apply') AS cvm_filters,
          count(DISTINCT user_id) FILTER (WHERE event_name LIKE 'portfolio%' OR event_name LIKE '%filter_portfolio%') AS unique_users
        FROM public.usage_events
        WHERE event_name IN ('portfolio_add_asset','portfolio_remove_asset','portfolio_save','portfolio_load','content_filter_portfolio_apply','cvm_filter_portfolio_apply')
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'portfolio_top_tickers', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT ticker, count(*) AS adds, count(DISTINCT user_id) AS unique_users
        FROM public.usage_events
        WHERE event_name = 'portfolio_add_asset' AND ticker IS NOT NULL
        GROUP BY ticker ORDER BY adds DESC LIMIT 15
      ) t
    ),
    'cvm_activity_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
          count(*) FILTER (WHERE event_name = 'cvm_doc_expand') AS expansions,
          count(*) FILTER (WHERE event_name = 'cvm_filter_portfolio_apply') AS filters,
          count(DISTINCT user_id) AS unique_users
        FROM public.usage_events
        WHERE event_name IN ('cvm_doc_expand','cvm_filter_portfolio_apply')
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'tab_usage', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT coalesce(feature, '(sem feature)') AS feature,
               coalesce(tab, '(sem tab)') AS tab,
               count(*) AS views,
               count(DISTINCT user_id) AS unique_users
        FROM public.usage_events
        WHERE event_name = 'tab_view'
        GROUP BY feature, tab ORDER BY views DESC LIMIT 30
      ) t
    )
  );

  -- ===== Alert rules analytics =====
  result := result || jsonb_build_object(
    'alert_rules_summary', (
      SELECT jsonb_build_object(
        'total_rules', (SELECT count(*) FROM public.alert_rules),
        'active_rules', (SELECT count(*) FROM public.alert_rules WHERE active = true),
        'unique_users', (SELECT count(DISTINCT user_id) FROM public.alert_rules),
        'avg_rules_per_user', (SELECT coalesce(round(count(*)::numeric / nullif(count(DISTINCT user_id), 0), 2), 0) FROM public.alert_rules),
        'by_type', (SELECT coalesce(jsonb_object_agg(rule_type, cnt), '{}'::jsonb) FROM (SELECT rule_type, count(*) AS cnt FROM public.alert_rules GROUP BY rule_type) s)
      )
    ),
    'alert_rules_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               rule_type,
               count(*) AS cnt
        FROM public.alert_rules
        GROUP BY day, rule_type ORDER BY day ASC
      ) t
    ),
    'alert_rules_top_tickers', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT ticker, count(*) AS cnt, count(DISTINCT user_id) AS unique_users,
               count(*) FILTER (WHERE active) AS active_cnt
        FROM public.alert_rules
        WHERE ticker IS NOT NULL
        GROUP BY ticker ORDER BY cnt DESC LIMIT 15
      ) t
    )
  );

  -- ===== Activation funnel (investor_profiles) =====
  result := result || jsonb_build_object(
    'activation_funnel', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT activation_stage AS stage, count(*) AS users
        FROM public.investor_profiles
        GROUP BY activation_stage
        ORDER BY CASE activation_stage
          WHEN 'new' THEN 1 WHEN 'exploring' THEN 2 WHEN 'portfolio_set' THEN 3
          WHEN 'active' THEN 4 WHEN 'power_user' THEN 5 ELSE 6 END
      ) t
    ),
    'activation_summary', (
      SELECT jsonb_build_object(
        'total_profiles', (SELECT count(*) FROM public.investor_profiles),
        'companion_trials', (SELECT count(*) FROM public.investor_profiles WHERE companion_trial_used = true),
        'profiling_completed', (SELECT count(*) FROM public.investor_profiles WHERE profiling_completed_at IS NOT NULL),
        'avg_companion_tools', (SELECT coalesce(round(avg(companion_tool_count)::numeric, 2), 0) FROM public.investor_profiles)
      )
    )
  );

  -- ===== Email & WhatsApp outbound =====
  result := result || jsonb_build_object(
    'email_log_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               email_type,
               count(*) AS sent,
               count(*) FILTER (WHERE status != 'sent' AND status IS NOT NULL) AS failed
        FROM public.email_log
        GROUP BY day, email_type ORDER BY day ASC
      ) t
    ),
    'email_log_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT email_type,
               count(*) AS total,
               count(*) FILTER (WHERE status = 'sent') AS sent,
               count(*) FILTER (WHERE status != 'sent' AND status IS NOT NULL) AS failed,
               count(DISTINCT recipient_user_id) AS unique_recipients
        FROM public.email_log GROUP BY email_type ORDER BY total DESC
      ) t
    ),
    'whatsapp_log_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               category,
               count(*) AS sent
        FROM public.whatsapp_log
        GROUP BY day, category ORDER BY day ASC
      ) t
    ),
    'whatsapp_log_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT category, count(*) AS total, count(DISTINCT recipient_user_id) AS unique_recipients
        FROM public.whatsapp_log GROUP BY category ORDER BY total DESC
      ) t
    )
  );

  RETURN result;

END;
$function$


-- Permissions
GRANT EXECUTE ON FUNCTION public.get_analytics_data() TO anon, authenticated, service_role;
