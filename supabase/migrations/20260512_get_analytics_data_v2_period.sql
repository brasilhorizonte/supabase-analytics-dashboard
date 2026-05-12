-- ============================================================================
-- 20260512_get_analytics_data_v2_period.sql
-- ============================================================================
-- Acelera o dashboard de analytics ao parametrizar as 4 RPCs principais com
-- janela temporal (p_from, p_to). Antes, get_analytics_data() rodava ~2.8s
-- mesmo quando o usuario filtrava 7d/30d porque agregava all-time em
-- usage_events (87k+ linhas). Com filtro temporal, ~200-400ms.
--
-- Padrao additivo (mesmo de get_analytics_data_bh_extras_v2 em 20260503):
-- as funcoes v1 permanecem intactas para rollback. Edge Function passa a
-- chamar as _v2 e passa {p_from, p_to}.
--
-- Aplicar no projeto: brasilhorizonte (dawvgbopyemcayavcatd)
-- ============================================================================

-- ============================================================
-- 1) get_analytics_data_v2 -- clone da RPC base com filtro temporal
--    em ~45 secoes daily/timeline. Secoes all-time preservadas:
--    overview, last_24h, top_tickers_market, sector_distribution,
--    table_sizes, subscribers_overview, subscribers_by_plan,
--    retention_cohorts, mrr_estimate, subscription_age,
--    watchlist_summary, revenue_by_plan, ticker_ranking,
--    user_ticker_usage, user_ticker_detail, user_inactivity,
--    inactivity_distribution, user_feature_breadth,
--    iacoes_overview (lifetime totals), time_to_convert,
--    top_reports_downloaded.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_analytics_data_v2(p_from timestamptz DEFAULT now() - interval '30 days', p_to timestamptz DEFAULT now())
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
        WHERE event_ts BETWEEN p_from AND p_to
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
        WHERE event_ts BETWEEN p_from AND p_to
        GROUP BY day
        ORDER BY day ASC
      ) t
    ),
    'feature_usage', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT feature, count(*) as cnt
        FROM public.usage_events
        WHERE feature IS NOT NULL AND event_ts BETWEEN p_from AND p_to
        GROUP BY feature
        ORDER BY cnt DESC
        LIMIT 10
      ) t
    ),
    'feature_usage_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               feature, count(*) as cnt
        FROM public.usage_events
        WHERE feature IS NOT NULL AND event_ts BETWEEN p_from AND p_to
        GROUP BY day, feature
        ORDER BY day ASC
      ) t
    ),
    'conversion_funnel', (
      SELECT jsonb_build_object(
        'sessions', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'session_start' AND user_id IS NOT NULL AND event_ts BETWEEN p_from AND p_to),
        'logins', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'auth_login' AND event_ts BETWEEN p_from AND p_to),
        'paywall_blocks', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'paywall_block' AND event_ts BETWEEN p_from AND p_to),
        'checkout_starts', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'checkout_start' AND event_ts BETWEEN p_from AND p_to),
        'payments', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'payment_succeeded' AND event_ts BETWEEN p_from AND p_to),
        'cancels', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'subscription_cancel' AND event_ts BETWEEN p_from AND p_to)
      )
    ),
    'device_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT device_type, count(*) as cnt, count(DISTINCT user_id) as unique_users
        FROM public.usage_events WHERE device_type IS NOT NULL AND event_ts BETWEEN p_from AND p_to
        GROUP BY device_type ORDER BY cnt DESC
      ) t
    ),
    'device_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               device_type, count(*) as cnt, count(DISTINCT user_id) as unique_users
        FROM public.usage_events WHERE device_type IS NOT NULL AND event_ts BETWEEN p_from AND p_to
        GROUP BY day, device_type ORDER BY day ASC
      ) t
    ),
    'os_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT os, count(*) as cnt FROM public.usage_events
        WHERE os IS NOT NULL AND event_ts BETWEEN p_from AND p_to GROUP BY os ORDER BY cnt DESC
      ) t
    ),
    'browser_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT browser, count(*) as cnt FROM public.usage_events
        WHERE browser IS NOT NULL AND event_ts BETWEEN p_from AND p_to GROUP BY browser ORDER BY cnt DESC
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
        FROM public.report_downloads WHERE created_at BETWEEN p_from AND p_to GROUP BY day ORDER BY day ASC
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
        WHERE ticker IS NOT NULL AND ticker != '' AND event_ts BETWEEN p_from AND p_to
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
        FROM public.profiles WHERE created_at BETWEEN p_from AND p_to GROUP BY day ORDER BY day ASC
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
          count(*) FILTER (WHERE event_name = 'subscription_cancel') as cancels
        FROM public.usage_events
        WHERE event_name IN ('paywall_block','checkout_start','checkout_complete','payment_succeeded','subscription_cancel')
          AND event_ts BETWEEN p_from AND p_to
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
        FROM public.usage_events WHERE route IS NOT NULL AND event_ts BETWEEN p_from AND p_to
        GROUP BY route ORDER BY views DESC LIMIT 10
      ) t
    ),
    'top_landing_pages', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT split_part(landing_page, '?', 1) as landing,
               count(*) as entries, count(DISTINCT user_id) as unique_users
        FROM public.usage_events
        WHERE landing_page IS NOT NULL AND event_name = 'session_start' AND event_ts BETWEEN p_from AND p_to
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
        WHERE event_name = 'session_start' AND event_ts BETWEEN p_from AND p_to
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
          AND event_ts BETWEEN p_from AND p_to
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
        WHERE event_name = 'session_start' AND event_ts BETWEEN p_from AND p_to
        GROUP BY 1, 2 ORDER BY day ASC
      ) t
    ),
    'screen_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT screen, count(*) as cnt FROM public.usage_events
        WHERE screen IS NOT NULL AND event_ts BETWEEN p_from AND p_to GROUP BY screen ORDER BY cnt DESC LIMIT 10
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
          FROM public.usage_events WHERE session_id IS NOT NULL AND event_ts BETWEEN p_from AND p_to
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
          FROM public.usage_events WHERE user_id IS NOT NULL AND event_ts BETWEEN p_from AND p_to
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
          FROM public.usage_events WHERE user_id IS NOT NULL AND event_ts BETWEEN p_from AND p_to
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
        FROM public.usage_events WHERE event_ts BETWEEN p_from AND p_to GROUP BY dow, hour ORDER BY dow, hour
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
          WHERE event_name = 'paywall_block' AND session_id IS NOT NULL AND event_ts BETWEEN p_from AND p_to
        ) AND feature IS NOT NULL AND event_name = 'feature_open' AND event_ts BETWEEN p_from AND p_to
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
        FROM public.usage_events WHERE section IS NOT NULL AND event_ts BETWEEN p_from AND p_to
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
        WHERE created_at BETWEEN p_from AND p_to
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
        WHERE created_at BETWEEN p_from AND p_to
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
        WHERE created_at BETWEEN p_from AND p_to
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
        WHERE created_at BETWEEN p_from AND p_to
        GROUP BY 1, 2 ORDER BY day ASC
      ) t
    ),
    'iacoes_devices', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT device_type, count(*) as views, count(DISTINCT session_id) as sessions
        FROM public.iacoes_page_views_human WHERE device_type IS NOT NULL AND created_at BETWEEN p_from AND p_to
        GROUP BY device_type ORDER BY views DESC
      ) t
    ),
    'iacoes_browsers', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT browser, count(*) as views
        FROM public.iacoes_page_views_human WHERE browser IS NOT NULL AND created_at BETWEEN p_from AND p_to
        GROUP BY browser ORDER BY views DESC
      ) t
    ),
    'iacoes_os', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT os, count(*) as views
        FROM public.iacoes_page_views_human WHERE os IS NOT NULL AND created_at BETWEEN p_from AND p_to
        GROUP BY os ORDER BY views DESC
      ) t
    ),
    'iacoes_utm', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT utm_source, utm_medium, utm_campaign, count(*) as views, count(DISTINCT session_id) as sessions
        FROM public.iacoes_page_views_human
        WHERE utm_source IS NOT NULL AND created_at BETWEEN p_from AND p_to
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
        WHERE created_at BETWEEN p_from AND p_to
        GROUP BY 1, 2, 3
        ORDER BY total DESC
      ) t
    )
  ) INTO result;

  -- iAcoes -> BH Conversion Analysis
  result := result || jsonb_build_object(
    'iacoes_conversion_funnel', (
      SELECT jsonb_build_object(
        'iacoes_views', (SELECT count(*) FROM public.iacoes_page_views_human WHERE (event_type = 'pageview' OR event_type IS NULL) AND created_at BETWEEN p_from AND p_to),
        'cta_clicks', (SELECT count(*) FROM public.iacoes_page_views_human WHERE event_type = 'cta_click' AND created_at BETWEEN p_from AND p_to),
        'bh_sessions', (SELECT count(*) FROM public.usage_events WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%' AND event_ts BETWEEN p_from AND p_to),
        'bh_unique_users', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%' AND user_id IS NOT NULL AND event_ts BETWEEN p_from AND p_to),
        'bh_logins', (SELECT count(*) FROM public.usage_events WHERE event_name = 'auth_login' AND event_ts BETWEEN p_from AND p_to AND session_id IN (SELECT DISTINCT session_id FROM public.usage_events WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%' AND event_ts BETWEEN p_from AND p_to)),
        'bh_paywall', (SELECT count(*) FROM public.usage_events WHERE event_name = 'paywall_block' AND event_ts BETWEEN p_from AND p_to AND session_id IN (SELECT DISTINCT session_id FROM public.usage_events WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%' AND event_ts BETWEEN p_from AND p_to)),
        'bh_payments', (SELECT count(*) FROM public.usage_events WHERE event_name = 'payment_succeeded' AND event_ts BETWEEN p_from AND p_to AND session_id IN (SELECT DISTINCT session_id FROM public.usage_events WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%' AND event_ts BETWEEN p_from AND p_to))
      )
    ),
    'iacoes_conversion_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH iacoes_sessions AS (
          SELECT DISTINCT session_id FROM public.usage_events
          WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%' AND event_ts BETWEEN p_from AND p_to
        )
        SELECT date_trunc('day', ue.event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
          count(*) FILTER (WHERE ue.event_name = 'session_start' AND ue.referrer ILIKE '%iacoes%') as sessions,
          count(DISTINCT ue.user_id) FILTER (WHERE ue.event_name = 'session_start' AND ue.referrer ILIKE '%iacoes%') as unique_users,
          count(*) FILTER (WHERE ue.event_name = 'auth_login') as logins,
          count(*) FILTER (WHERE ue.event_name = 'paywall_block') as paywall,
          count(*) FILTER (WHERE ue.event_name = 'checkout_start') as checkout,
          count(*) FILTER (WHERE ue.event_name = 'payment_succeeded') as payments
        FROM public.usage_events ue
        WHERE ue.session_id IN (SELECT session_id FROM iacoes_sessions) AND ue.event_ts BETWEEN p_from AND p_to
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
        WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%' AND event_ts BETWEEN p_from AND p_to
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
          FROM public.usage_events WHERE event_name = 'session_start' AND event_ts BETWEEN p_from AND p_to
        )
        SELECT ss.source,
          count(DISTINCT ss.session_id) as sessions,
          count(DISTINCT ue_login.session_id) as logins,
          count(DISTINCT ue_pay.session_id) as paywall,
          round(count(DISTINCT ue_login.session_id)::numeric / nullif(count(DISTINCT ss.session_id), 0) * 100, 1) as login_rate,
          round(count(DISTINCT ue_pay.session_id)::numeric / nullif(count(DISTINCT ss.session_id), 0) * 100, 1) as paywall_rate
        FROM source_sessions ss
        LEFT JOIN public.usage_events ue_login ON ue_login.session_id = ss.session_id AND ue_login.event_name = 'auth_login' AND ue_login.event_ts BETWEEN p_from AND p_to
        LEFT JOIN public.usage_events ue_pay ON ue_pay.session_id = ss.session_id AND ue_pay.event_name = 'paywall_block' AND ue_pay.event_ts BETWEEN p_from AND p_to
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
        WHERE ticker IS NOT NULL AND ticker != '' AND feature IS NOT NULL AND event_ts BETWEEN p_from AND p_to
        GROUP BY feature, ticker ORDER BY feature, cnt DESC
      ) t
    ),
    'ticker_trend_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH top_tickers AS (
          SELECT ticker FROM public.usage_events
          WHERE ticker IS NOT NULL AND ticker != ''
          GROUP BY ticker ORDER BY count(*) DESC LIMIT 30
        )
        SELECT day, ticker, cnt FROM (
          SELECT date_trunc('day', ue.event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
                 ue.ticker, count(*) as cnt
          FROM public.usage_events ue
          JOIN top_tickers tt ON tt.ticker = ue.ticker
          WHERE ue.event_ts BETWEEN p_from AND p_to
          GROUP BY day, ue.ticker
          UNION ALL
          SELECT date_trunc('day', ue.event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
                 'Outros' as ticker, count(*) as cnt
          FROM public.usage_events ue
          WHERE ue.ticker IS NOT NULL AND ue.ticker != ''
            AND ue.ticker NOT IN (SELECT ticker FROM top_tickers)
            AND ue.event_ts BETWEEN p_from AND p_to
          GROUP BY day
        ) sub ORDER BY day ASC
      ) t
    ),
    'feature_usage_trend', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               feature, count(*) as cnt, count(DISTINCT user_id) as unique_users,
               count(DISTINCT ticker) as unique_tickers
        FROM public.usage_events
        WHERE feature IS NOT NULL AND ticker IS NOT NULL AND ticker != '' AND event_ts BETWEEN p_from AND p_to
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
        WHERE event_name = 'auth_login' AND event_ts BETWEEN p_from AND p_to
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'monthly_active_users', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('month', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as month,
               count(DISTINCT user_id) as unique_users
        FROM public.usage_events
        WHERE user_id IS NOT NULL AND event_ts BETWEEN p_from AND p_to
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
                 WHEN plan = 'ianalista' AND billing_period = 'monthly' THEN count(*) * 99.90
                 WHEN plan = 'ianalista' AND billing_period = 'yearly' THEN count(*) * 899.90 / 12
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
        WHERE created_at BETWEEN p_from AND p_to
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
          WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%' AND event_ts BETWEEN p_from AND p_to
        )
        SELECT s.day, s.ticker,
               count(DISTINCT s.session_id) as sessions,
               count(DISTINCT s.user_id) as unique_users,
               count(DISTINCT CASE WHEN ue_l.session_id IS NOT NULL THEN s.session_id END) as led_to_login,
               count(DISTINCT CASE WHEN ue_p.session_id IS NOT NULL THEN s.session_id END) as led_to_paywall
        FROM iacoes_sess s
        LEFT JOIN public.usage_events ue_l ON ue_l.session_id = s.session_id AND ue_l.event_name = 'auth_login' AND ue_l.event_ts BETWEEN p_from AND p_to
        LEFT JOIN public.usage_events ue_p ON ue_p.session_id = s.session_id AND ue_p.event_name = 'paywall_block' AND ue_p.event_ts BETWEEN p_from AND p_to
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
        WHERE event_type = 'cta_click' AND created_at BETWEEN p_from AND p_to
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
        WHERE event_type = 'cta_click' AND created_at BETWEEN p_from AND p_to
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
        WHERE event_type = 'cta_click' AND created_at BETWEEN p_from AND p_to
        GROUP BY day, cta_id
        ORDER BY day ASC
      ) t
    )
  );

  RETURN result;

END;
$function$;


GRANT EXECUTE ON FUNCTION public.get_analytics_data_v2(timestamptz, timestamptz) TO anon, authenticated, service_role;

-- ============================================================
-- 2) get_analytics_data_iacoes_daily_v2 -- aceita p_from/p_to
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_analytics_data_iacoes_daily_v2(p_from timestamptz DEFAULT now() - interval '30 days', p_to timestamptz DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(

    -- Devices por dia
    'iacoes_devices_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               device_type,
               count(*) as views,
               count(DISTINCT session_id) as sessions
        FROM public.iacoes_page_views_human
        WHERE device_type IS NOT NULL AND created_at BETWEEN p_from AND p_to
        GROUP BY day, device_type
        ORDER BY day ASC
      ) t
    ),

    -- Browsers por dia
    'iacoes_browsers_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               browser,
               count(*) as views
        FROM public.iacoes_page_views_human
        WHERE browser IS NOT NULL AND created_at BETWEEN p_from AND p_to
        GROUP BY day, browser
        ORDER BY day ASC
      ) t
    ),

    -- OS por dia
    'iacoes_os_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               os,
               count(*) as views
        FROM public.iacoes_page_views_human
        WHERE os IS NOT NULL AND created_at BETWEEN p_from AND p_to
        GROUP BY day, os
        ORDER BY day ASC
      ) t
    ),

    -- UTM por dia
    'iacoes_utm_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               utm_source,
               utm_medium,
               utm_campaign,
               count(*) as views,
               count(DISTINCT session_id) as sessions
        FROM public.iacoes_page_views_human
        WHERE utm_source IS NOT NULL AND created_at BETWEEN p_from AND p_to
        GROUP BY day, utm_source, utm_medium, utm_campaign
        ORDER BY day ASC
      ) t
    ),

    -- CTA breakdown por dia (cta_id, clicks, unique_sessions)
    'iacoes_cta_breakdown_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               coalesce(cta_id, 'sem_id') as cta_id,
               count(*) as clicks,
               count(DISTINCT session_id) as unique_sessions
        FROM public.iacoes_page_views_human
        WHERE event_type = 'cta_click' AND created_at BETWEEN p_from AND p_to
        GROUP BY day, cta_id
        ORDER BY day ASC
      ) t
    ),

    -- CTA por pagina por dia
    'iacoes_cta_by_page_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               coalesce(cta_id, 'sem_id') as cta_id,
               page_path,
               count(*) as clicks
        FROM public.iacoes_page_views_human
        WHERE event_type = 'cta_click' AND created_at BETWEEN p_from AND p_to
        GROUP BY day, cta_id, page_path
        ORDER BY day ASC
      ) t
    ),

    -- Source detection por dia (Dark Social & Ads)
    'iacoes_source_detection_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               coalesce(source_hint, 'nenhum') as source_hint,
               coalesce(click_id_source, 'nenhum') as click_id_source,
               CASE
                 WHEN referrer IS NULL OR referrer = '' THEN 'vazio'
                 ELSE 'presente'
               END as referrer_status,
               count(*) as total
        FROM public.iacoes_page_views_human
        WHERE created_at BETWEEN p_from AND p_to
        GROUP BY day, source_hint, click_id_source, referrer_status
        ORDER BY day ASC
      ) t
    ),

    -- Hourly breakdown da landing (por dia + hora) -- frontend agrega por hora-do-dia
    'iacoes_hourly_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date as day,
               extract(hour from created_at AT TIME ZONE 'America/Sao_Paulo')::int as hour,
               extract(dow from created_at AT TIME ZONE 'America/Sao_Paulo')::int as dow,
               count(*) FILTER (WHERE event_type = 'pageview' OR event_type IS NULL) as views,
               count(DISTINCT session_id) as sessions,
               count(*) FILTER (WHERE event_type = 'cta_click') as cta_clicks
        FROM public.iacoes_page_views_human
        WHERE created_at BETWEEN p_from AND p_to
        GROUP BY day, hour, dow
        ORDER BY day ASC, hour ASC
      ) t
    ),

    -- Hourly conversion breakdown (BH sessions atribuidas a iAcoes por dia + hora)
    'iacoes_conversion_hourly_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH iacoes_sessions AS (
          SELECT DISTINCT session_id FROM public.usage_events
          WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%' AND event_ts BETWEEN p_from AND p_to
        )
        SELECT date_trunc('day', ue.event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               extract(hour from ue.event_ts AT TIME ZONE 'America/Sao_Paulo')::int as hour,
               extract(dow from ue.event_ts AT TIME ZONE 'America/Sao_Paulo')::int as dow,
               count(*) FILTER (WHERE ue.event_name = 'session_start' AND ue.referrer ILIKE '%iacoes%') as sessions,
               count(*) FILTER (WHERE ue.event_name = 'auth_login') as logins,
               count(*) FILTER (WHERE ue.event_name = 'paywall_block') as paywall,
               count(*) FILTER (WHERE ue.event_name = 'payment_succeeded') as payments
        FROM public.usage_events ue
        WHERE ue.session_id IN (SELECT session_id FROM iacoes_sessions) AND ue.event_ts BETWEEN p_from AND p_to
        GROUP BY day, hour, dow
        ORDER BY day ASC, hour ASC
      ) t
    ),

    -- iAcoes vs Outras Fontes por dia (valores absolutos -- frontend calcula taxas)
    -- Mesmo case statement de iacoes_vs_other_conversion para preservar mapping
    'iacoes_vs_other_conversion_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH source_sessions AS (
          SELECT session_id,
                 date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
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
          FROM public.usage_events
          WHERE event_name = 'session_start' AND event_ts BETWEEN p_from AND p_to
        )
        SELECT ss.day,
               ss.source,
               count(DISTINCT ss.session_id) as sessions,
               count(DISTINCT ue_login.session_id) as logins,
               count(DISTINCT ue_pay.session_id) as paywall
        FROM source_sessions ss
        LEFT JOIN public.usage_events ue_login
               ON ue_login.session_id = ss.session_id
              AND ue_login.event_name = 'auth_login'
              AND ue_login.event_ts BETWEEN p_from AND p_to
        LEFT JOIN public.usage_events ue_pay
               ON ue_pay.session_id = ss.session_id
              AND ue_pay.event_name = 'paywall_block'
              AND ue_pay.event_ts BETWEEN p_from AND p_to
        GROUP BY ss.day, ss.source
        ORDER BY ss.day ASC
      ) t
    )

  ) INTO result;

  RETURN result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_analytics_data_iacoes_daily_v2(timestamptz, timestamptz) TO anon, authenticated, service_role;

-- ============================================================
-- 3) get_analytics_data_bh_utm_v2 -- p_from substitui o window_start
--    hardcoded de 90d. promo_start/promo_end da campanha 50OFF
--    permanecem hardcoded (campanha tem janela fixa).
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_analytics_data_bh_utm_v2(p_from timestamptz DEFAULT now() - interval '90 days', p_to timestamptz DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  promo_start  timestamptz := '2026-04-27 00:00:00-03'::timestamptz;
  promo_end    timestamptz := '2026-05-03 23:59:59-03'::timestamptz;
BEGIN
  result := jsonb_build_object(

    -- ===== Top sources/mediums/campaigns (last 90d) =====
    'usage_utm_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          coalesce(utm_source, '(none)')   AS utm_source,
          coalesce(utm_medium, '(none)')   AS utm_medium,
          coalesce(utm_campaign, '(none)') AS utm_campaign,
          count(*)                                                                       AS events,
          count(DISTINCT session_id)                                                     AS sessions,
          count(DISTINCT user_id) FILTER (WHERE user_id IS NOT NULL)                     AS unique_users,
          count(*) FILTER (WHERE event_name = 'auth_login')                              AS logins,
          count(*) FILTER (WHERE event_name LIKE 'paywall%' OR event_name = 'paywall_block') AS paywall_events,
          count(*) FILTER (WHERE event_name = 'payment_succeeded')                       AS payments
        FROM public.usage_events
        WHERE event_ts BETWEEN p_from AND p_to
          AND (utm_source IS NOT NULL OR utm_medium IS NOT NULL OR utm_campaign IS NOT NULL)
        GROUP BY 1, 2, 3
        ORDER BY events DESC
        LIMIT 30
      ) t
    ),

    -- ===== Daily series by source (last 90d) — for stacked bar chart =====
    'usage_utm_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
          coalesce(utm_source, '(none)') AS utm_source,
          count(*)                       AS events,
          count(DISTINCT session_id)     AS sessions
        FROM public.usage_events
        WHERE event_ts BETWEEN p_from AND p_to
          AND utm_source IS NOT NULL
        GROUP BY 1, 2
        ORDER BY 1 ASC
      ) t
    ),

    -- ===== Breakdown by utm_content (creative-level performance) =====
    -- Naming convention used by the campaign: {feature}_{channel}_{format}
    -- e.g. valuai_yt_video, score_ig_reel, radar_tw_thread
    'usage_utm_by_content', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          utm_content,
          coalesce(utm_source, '(none)')   AS utm_source,
          coalesce(utm_medium, '(none)')   AS utm_medium,
          coalesce(utm_campaign, '(none)') AS utm_campaign,
          count(*)                                                       AS events,
          count(DISTINCT session_id)                                     AS sessions,
          count(DISTINCT user_id) FILTER (WHERE user_id IS NOT NULL)     AS unique_users,
          count(*) FILTER (WHERE event_name = 'auth_login')              AS logins,
          count(*) FILTER (WHERE event_name = 'payment_succeeded')       AS payments
        FROM public.usage_events
        WHERE event_ts BETWEEN p_from AND p_to
          AND utm_content IS NOT NULL
        GROUP BY 1, 2, 3, 4
        ORDER BY events DESC
        LIMIT 50
      ) t
    ),

    -- ===== Conversion funnel by source (session-level join) =====
    -- Maps utm_source -> %sessions that reached login/paywall/payment.
    -- This is the chart that answers "which channel converts best?".
    'usage_utm_funnel_by_source', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH attributed_sessions AS (
          SELECT DISTINCT session_id, user_id, coalesce(utm_source, '(none)') AS utm_source
          FROM public.usage_events
          WHERE event_ts BETWEEN p_from AND p_to
            AND utm_source IS NOT NULL
            AND session_id IS NOT NULL
        )
        SELECT
          a.utm_source,
          count(DISTINCT a.session_id) AS sessions,
          count(DISTINCT a.session_id) FILTER (
            WHERE EXISTS (
              SELECT 1 FROM public.usage_events e
              WHERE e.session_id = a.session_id AND e.event_name = 'auth_login'
            )
          ) AS sessions_with_login,
          count(DISTINCT a.session_id) FILTER (
            WHERE EXISTS (
              SELECT 1 FROM public.usage_events e
              WHERE e.session_id = a.session_id
                AND (e.event_name LIKE 'paywall%' OR e.event_name = 'paywall_block')
            )
          ) AS sessions_with_paywall,
          count(DISTINCT a.session_id) FILTER (
            WHERE EXISTS (
              SELECT 1 FROM public.usage_events e
              WHERE e.session_id = a.session_id AND e.event_name = 'payment_succeeded'
            )
          ) AS sessions_with_payment
        FROM attributed_sessions a
        GROUP BY a.utm_source
        HAVING count(DISTINCT a.session_id) >= 3
        ORDER BY sessions DESC
        LIMIT 20
      ) t
    ),

    -- ===== Campaign 50OFF specific snapshot (Apr 2026) =====
    -- Hard-coded date window because the campaign has a defined start/end.
    -- Replace or add new blocks for future campaigns.
    'usage_utm_50off_summary', (
      SELECT jsonb_build_object(
        'campaign_id',          '50off_apr2026',
        'window_start',         promo_start,
        'window_end',           promo_end,
        'events',               (SELECT count(*) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end),
        'sessions',             (SELECT count(DISTINCT session_id) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end),
        'unique_users',         (SELECT count(DISTINCT user_id) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end
                                    AND user_id IS NOT NULL),
        'logins',               (SELECT count(*) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end
                                    AND event_name = 'auth_login'),
        'signups',              (SELECT count(DISTINCT user_id) FROM public.usage_events
                                  WHERE session_id IN (
                                    SELECT DISTINCT session_id FROM public.usage_events
                                    WHERE utm_campaign = '50off_apr2026'
                                      AND event_ts BETWEEN promo_start AND promo_end
                                  )
                                  AND event_name = 'auth_signup'),
        'paywall_views',        (SELECT count(*) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end
                                    AND (event_name LIKE 'paywall%' OR event_name = 'paywall_block')),
        'checkout_starts',      (SELECT count(*) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end
                                    AND event_name IN ('checkout_started','credit_exhausted_checkout_start')),
        'payments',             (SELECT count(*) FROM public.usage_events
                                  WHERE utm_campaign = '50off_apr2026'
                                    AND event_ts BETWEEN promo_start AND promo_end
                                    AND event_name = 'payment_succeeded')
      )
    ),

    -- Daily breakdown for the 50OFF campaign — used for time-series chart
    'usage_utm_50off_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
          coalesce(utm_source, '(none)') AS utm_source,
          count(*)                                                       AS events,
          count(DISTINCT session_id)                                     AS sessions,
          count(*) FILTER (WHERE event_name = 'payment_succeeded')       AS payments
        FROM public.usage_events
        WHERE utm_campaign = '50off_apr2026'
          AND event_ts BETWEEN promo_start AND promo_end
        GROUP BY 1, 2
        ORDER BY 1 ASC
      ) t
    ),

    -- 50OFF campaign — top creatives (utm_content)
    -- Answers "which video/reel/thread drove the most conversions?".
    'usage_utm_50off_top_content', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          utm_content,
          coalesce(utm_source, '(none)') AS utm_source,
          coalesce(utm_medium, '(none)') AS utm_medium,
          count(*)                                                  AS events,
          count(DISTINCT session_id)                                AS sessions,
          count(*) FILTER (WHERE event_name = 'auth_login')         AS logins,
          count(*) FILTER (WHERE event_name = 'payment_succeeded')  AS payments
        FROM public.usage_events
        WHERE utm_campaign = '50off_apr2026'
          AND event_ts BETWEEN promo_start AND promo_end
          AND utm_content IS NOT NULL
        GROUP BY 1, 2, 3
        ORDER BY events DESC
        LIMIT 30
      ) t
    )
  );

  RETURN result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_analytics_data_bh_utm_v2(timestamptz, timestamptz) TO anon, authenticated, service_role;

-- ============================================================
-- 4) get_analytics_data_bh_oauth_v2 -- aceita p_from/p_to
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_analytics_data_bh_oauth_v2(p_from timestamptz DEFAULT now() - interval '30 days', p_to timestamptz DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(

    -- Daily breakdown de auth_login por (method, action) -- frontend agrega
    'oauth_login_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               coalesce(properties->>'method', 'unknown') as method,
               action,
               count(*) as cnt
        FROM public.usage_events
        WHERE event_name = 'auth_login'
          AND action IN ('started','success','error')
          AND event_ts BETWEEN p_from AND p_to
        GROUP BY 1, 2, 3
        ORDER BY 1 ASC
      ) t
    ),

    -- Primeiro auth_login success por user (proxy para "novo signup") agrupado por dia + method
    'oauth_first_login_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH first_login AS (
          SELECT DISTINCT ON (user_id)
                 user_id,
                 (event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
                 coalesce(properties->>'method', 'unknown') as method
          FROM public.usage_events
          WHERE event_name = 'auth_login'
            AND action = 'success'
            AND user_id IS NOT NULL
            AND event_ts BETWEEN p_from AND p_to
          ORDER BY user_id, event_ts ASC
        )
        SELECT day, method, count(*) as cnt
        FROM first_login
        GROUP BY day, method
        ORDER BY day ASC
      ) t
    ),

    -- Profile type onboarding (1a vez por user) cruzado com method (google/email)
    'oauth_profile_type_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT (event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               coalesce(properties->>'method', 'unknown') as method,
               coalesce(properties->>'profile_type', 'unknown') as profile_type,
               count(*) as cnt
        FROM public.usage_events
        WHERE event_name = 'profile_type_onboarding_complete'
          AND action = 'success'
          AND event_ts BETWEEN p_from AND p_to
        GROUP BY 1, 2, 3
        ORDER BY 1 ASC
      ) t
    )

  ) INTO result;

  RETURN result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_analytics_data_bh_oauth_v2(timestamptz, timestamptz) TO anon, authenticated, service_role;

-- Refresh PostgREST schema cache for the new signatures
NOTIFY pgrst, 'reload schema';
