-- Migration: BH engagement v2 — admin filter + parameterized time window + lifetime fix
-- Date: 2026-05-03
-- Project: brasilhorizonte (dawvgbopyemcayavcatd)
--
-- Why:
--   1. Lifetime sections derived from public.lifetime_feature_usage are incomplete
--      (e.g. only 5 of 13 Macro Beta users were registered there). usage_events has
--      the authoritative `feature` column, so we derive lifetime metrics from there.
--   2. Admins (3 emails) inflated all engagement KPIs — gabriel.dantas alone owned
--      291 of ~340 macro_* events. New view usage_events_clean strips them.
--   3. Existing get_analytics_data_bh_extras() returns all-time aggregates only.
--      v2 accepts p_from/p_to so KPIs/funnels respect the dashboard's globalFilters.
--
-- Strategy: v1 RPC kept untouched (backward compat). v2 is the new entry point
-- the Edge Function will call.

-- ============================================================================
-- 1. View: usage_events filtered to exclude admins
-- ============================================================================

CREATE OR REPLACE VIEW public.usage_events_clean AS
SELECT ue.*
FROM public.usage_events ue
LEFT JOIN auth.users u ON u.id = ue.user_id
WHERE u.email IS NULL
   OR u.email NOT IN (
     'lucasmello@brasilhorizonte.com.br',
     'lucastnm@gmail.com',
     'gabriel.dantas@brasilhorizonte.com.br'
   );

GRANT SELECT ON public.usage_events_clean TO anon, authenticated, service_role;

-- ============================================================================
-- 2. RPC: get_analytics_data_bh_extras_v2(p_from, p_to)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_analytics_data_bh_extras_v2(
  p_from timestamptz DEFAULT (now() - interval '30 days'),
  p_to   timestamptz DEFAULT now()
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  v_admins_excluded text[] := ARRAY[
    'lucasmello@brasilhorizonte.com.br',
    'lucastnm@gmail.com',
    'gabriel.dantas@brasilhorizonte.com.br'
  ];
BEGIN
  result := jsonb_build_object(
    'meta', jsonb_build_object(
      'from', p_from,
      'to', p_to,
      'admins_excluded', to_jsonb(v_admins_excluded),
      'source', 'usage_events_clean'
    ),

    -- ===== Revenue (unaffected by admin filter — based on profiles) =====
    'active_subscribers_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH first_payment AS (
          SELECT user_id, min(event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS first_paid_day
          FROM public.usage_events_clean
          WHERE event_name = 'payment_succeeded' AND user_id IS NOT NULL
          GROUP BY user_id
        ),
        last_cancel AS (
          SELECT user_id, max(event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS last_cancel_day
          FROM public.usage_events_clean
          WHERE event_name = 'subscription_cancel' AND user_id IS NOT NULL
          GROUP BY user_id
        ),
        day_series AS (
          SELECT generate_series(
            (p_from AT TIME ZONE 'America/Sao_Paulo')::date,
            (p_to   AT TIME ZONE 'America/Sao_Paulo')::date,
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
          FROM public.usage_events_clean
          WHERE event_name = 'payment_succeeded' AND user_id IS NOT NULL
          GROUP BY user_id
        )
        SELECT first_paid_day AS day, count(*) AS new_subs
        FROM first_payment
        WHERE first_paid_day BETWEEN (p_from AT TIME ZONE 'America/Sao_Paulo')::date
                                 AND (p_to   AT TIME ZONE 'America/Sao_Paulo')::date
        GROUP BY first_paid_day ORDER BY first_paid_day ASC
      ) t
    ),
    'trial_funnel_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH trials AS (
          SELECT user_id, min(event_ts) AS trial_ts
          FROM public.usage_events_clean
          WHERE event_name = 'trial_start' AND user_id IS NOT NULL
            AND event_ts BETWEEN p_from AND p_to
          GROUP BY user_id
        ),
        first_payment AS (
          SELECT user_id, min(event_ts) AS first_paid_ts
          FROM public.usage_events_clean
          WHERE event_name = 'payment_succeeded' AND user_id IS NOT NULL
          GROUP BY user_id
        )
        SELECT (t.trial_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               count(*) AS trials_started,
               count(*) FILTER (WHERE fp.first_paid_ts IS NOT NULL AND fp.first_paid_ts <= t.trial_ts + interval '14 days') AS trials_converted,
               count(*) FILTER (WHERE (fp.first_paid_ts IS NULL OR fp.first_paid_ts > t.trial_ts + interval '14 days') AND t.trial_ts + interval '14 days' < now()) AS trials_expired
        FROM trials t LEFT JOIN first_payment fp ON fp.user_id = t.user_id
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'subscription_trials_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               count(*) AS trials
        FROM public.usage_events_clean
        WHERE event_name = 'trial_start'
          AND event_ts BETWEEN p_from AND p_to
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'revenue_by_plan_fixed', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT plan, billing_period, count(*) AS subscribers,
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
          END AS mrr_estimate
        FROM public.profiles
        WHERE subscription_status = 'active' AND plan IS NOT NULL AND plan != 'free'
        GROUP BY plan, billing_period ORDER BY mrr_estimate DESC
      ) t
    ),

    -- ===== Portfolio (period-filtered, dedup: cvm_filter_portfolio_apply moved out) =====
    'portfolio_activity_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
          count(*) FILTER (WHERE event_name = 'portfolio_add_asset') AS adds,
          count(*) FILTER (WHERE event_name = 'portfolio_remove_asset') AS removes,
          count(*) FILTER (WHERE event_name = 'portfolio_save') AS saves,
          count(*) FILTER (WHERE event_name = 'portfolio_load') AS loads,
          count(*) FILTER (WHERE event_name = 'portfolio_delete') AS deletes,
          count(*) FILTER (WHERE event_name = 'portfolio_ianalise_run') AS ianalises,
          count(*) FILTER (WHERE event_name = 'content_filter_portfolio_apply') AS content_filters,
          count(*) FILTER (WHERE event_name = 'portfolio_photo_import_success') AS photo_imports,
          count(DISTINCT user_id) AS unique_users
        FROM public.usage_events_clean
        WHERE event_name IN (
          'portfolio_add_asset','portfolio_remove_asset','portfolio_save','portfolio_load',
          'portfolio_delete','portfolio_ianalise_run','content_filter_portfolio_apply',
          'portfolio_photo_import_success'
        )
          AND event_ts BETWEEN p_from AND p_to
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'portfolio_top_tickers', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT ticker, count(*) AS adds, count(DISTINCT user_id) AS unique_users
        FROM public.usage_events_clean
        WHERE event_name = 'portfolio_add_asset'
          AND ticker IS NOT NULL
          AND event_ts BETWEEN p_from AND p_to
        GROUP BY ticker ORDER BY adds DESC LIMIT 15
      ) t
    ),

    -- ===== CVM (period-filtered, owns cvm_filter_portfolio_apply exclusively) =====
    'cvm_activity_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
          count(*) FILTER (WHERE event_name = 'cvm_doc_expand') AS expansions,
          count(*) FILTER (WHERE event_name = 'cvm_filter_portfolio_apply') AS filters,
          count(*) FILTER (WHERE event_name = 'cvm_pdf_click') AS pdf_clicks,
          count(*) FILTER (WHERE event_name = 'cvm_telegram_cta_click') AS telegram_clicks,
          count(*) FILTER (WHERE event_name = 'cvm_telegram_cta_dismiss') AS telegram_dismisses,
          count(*) FILTER (WHERE event_name = 'cvm_filter_type_toggle') AS type_toggles,
          count(DISTINCT user_id) AS unique_users
        FROM public.usage_events_clean
        WHERE event_name IN (
          'cvm_doc_expand','cvm_filter_portfolio_apply','cvm_pdf_click',
          'cvm_telegram_cta_click','cvm_telegram_cta_dismiss','cvm_filter_type_toggle'
        )
          AND event_ts BETWEEN p_from AND p_to
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'cvm_interactions_summary', (
      SELECT jsonb_build_object(
        'doc_expands',         (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'cvm_doc_expand'             AND event_ts BETWEEN p_from AND p_to),
        'pdf_clicks',          (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'cvm_pdf_click'              AND event_ts BETWEEN p_from AND p_to),
        'filter_applies',      (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'cvm_filter_portfolio_apply' AND event_ts BETWEEN p_from AND p_to),
        'type_toggles',        (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'cvm_filter_type_toggle'     AND event_ts BETWEEN p_from AND p_to),
        'telegram_cta_clicks', (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'cvm_telegram_cta_click'     AND event_ts BETWEEN p_from AND p_to),
        'telegram_cta_dismisses',(SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'cvm_telegram_cta_dismiss' AND event_ts BETWEEN p_from AND p_to),
        'unique_users',        (SELECT count(DISTINCT user_id) FROM public.usage_events_clean WHERE event_name IN (
          'cvm_doc_expand','cvm_pdf_click','cvm_filter_portfolio_apply','cvm_filter_type_toggle',
          'cvm_telegram_cta_click','cvm_telegram_cta_dismiss'
        ) AND event_ts BETWEEN p_from AND p_to)
      )
    ),

    -- ===== tab_usage (period-filtered) =====
    'tab_usage', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT coalesce(feature, '(sem feature)') AS feature,
               coalesce(tab, '(sem tab)') AS tab,
               count(*) AS views,
               count(DISTINCT user_id) AS unique_users
        FROM public.usage_events_clean
        WHERE event_name = 'tab_view'
          AND event_ts BETWEEN p_from AND p_to
        GROUP BY feature, tab ORDER BY views DESC LIMIT 30
      ) t
    ),

    -- ===== Alerts (table-based, no time filter applied — alert_rules has its own lifecycle) =====
    'alert_rules_summary', (
      SELECT jsonb_build_object(
        'total_rules',  (SELECT count(*) FROM public.alert_rules),
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
               rule_type, count(*) AS cnt
        FROM public.alert_rules
        WHERE created_at BETWEEN p_from AND p_to
        GROUP BY day, rule_type ORDER BY day ASC
      ) t
    ),
    'alert_rules_top_tickers', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT ticker, count(*) AS cnt, count(DISTINCT user_id) AS unique_users,
               count(*) FILTER (WHERE active) AS active_cnt
        FROM public.alert_rules WHERE ticker IS NOT NULL
        GROUP BY ticker ORDER BY cnt DESC LIMIT 15
      ) t
    ),

    -- ===== Activation (profile-table snapshot) =====
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
    ),

    -- ===== Email/WhatsApp logs (period-filtered) =====
    'email_log_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               email_type, count(*) AS sent,
               count(*) FILTER (WHERE status != 'sent' AND status IS NOT NULL) AS failed
        FROM public.email_log
        WHERE created_at BETWEEN p_from AND p_to
        GROUP BY day, email_type ORDER BY day ASC
      ) t
    ),
    'email_log_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT email_type, count(*) AS total,
               count(*) FILTER (WHERE status = 'sent') AS sent,
               count(*) FILTER (WHERE status != 'sent' AND status IS NOT NULL) AS failed,
               count(DISTINCT recipient_user_id) AS unique_recipients
        FROM public.email_log
        WHERE created_at BETWEEN p_from AND p_to
        GROUP BY email_type ORDER BY total DESC
      ) t
    ),
    'whatsapp_log_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               category, count(*) AS sent
        FROM public.whatsapp_log
        WHERE created_at BETWEEN p_from AND p_to
        GROUP BY day, category ORDER BY day ASC
      ) t
    ),
    'whatsapp_log_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT category, count(*) AS total, count(DISTINCT recipient_user_id) AS unique_recipients
        FROM public.whatsapp_log
        WHERE created_at BETWEEN p_from AND p_to
        GROUP BY category ORDER BY total DESC
      ) t
    ),

    -- ===== Macro Beta (period-filtered, explicit event lists — no LIKE 'macro_%') =====
    'macro_beta_overview', (
      SELECT jsonb_build_object(
        'views',              (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'macro_beta_view'                AND event_ts BETWEEN p_from AND p_to),
        'runs_success',       (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'macro_beta_run_success'         AND event_ts BETWEEN p_from AND p_to),
        'runs_error',         (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'macro_beta_run_error'           AND event_ts BETWEEN p_from AND p_to),
        'verdicts_generated', (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'macro_verdict_generated'        AND event_ts BETWEEN p_from AND p_to),
        'drill_downs',        (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'macro_beta_drill_down'          AND event_ts BETWEEN p_from AND p_to),
        'tooltip_opens',      (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'macro_beta_factor_tooltip_open' AND event_ts BETWEEN p_from AND p_to),
        'sort_changes',       (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'macro_beta_sort_change'         AND event_ts BETWEEN p_from AND p_to),
        'upgrade_clicks',     (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'macro_beta_upgrade_click'       AND event_ts BETWEEN p_from AND p_to),
        'coupon_copies',      (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'macro_beta_coupon_copied'       AND event_ts BETWEEN p_from AND p_to),
        'unique_users',       (SELECT count(DISTINCT user_id) FROM public.usage_events_clean WHERE event_name IN (
          'macro_beta_view','macro_beta_run_success','macro_beta_run_error','macro_verdict_generated',
          'macro_beta_drill_down','macro_beta_factor_tooltip_open','macro_beta_sort_change',
          'macro_beta_upgrade_click','macro_beta_coupon_copied'
        ) AND event_ts BETWEEN p_from AND p_to),
        'saved_total',        (SELECT count(*) FROM public.macro_beta_saved_analyses WHERE created_at BETWEEN p_from AND p_to),
        'saved_unique_users', (SELECT count(DISTINCT user_id) FROM public.macro_beta_saved_analyses WHERE created_at BETWEEN p_from AND p_to)
      )
    ),
    'macro_beta_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
          count(*) FILTER (WHERE event_name = 'macro_beta_view') AS views,
          count(*) FILTER (WHERE event_name = 'macro_beta_run_success') AS runs_success,
          count(*) FILTER (WHERE event_name = 'macro_beta_run_error') AS runs_error,
          count(*) FILTER (WHERE event_name = 'macro_verdict_generated') AS verdicts,
          count(*) FILTER (WHERE event_name = 'macro_beta_drill_down') AS drill_downs,
          count(DISTINCT user_id) AS unique_users
        FROM public.usage_events_clean
        WHERE event_name IN (
          'macro_beta_view','macro_beta_run_success','macro_beta_run_error',
          'macro_verdict_generated','macro_beta_drill_down','macro_beta_factor_tooltip_open',
          'macro_beta_sort_change','macro_beta_upgrade_click','macro_beta_coupon_copied'
        )
          AND event_ts BETWEEN p_from AND p_to
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'macro_beta_funnel', (
      SELECT jsonb_build_object(
        'viewed',          (SELECT count(DISTINCT user_id) FROM public.usage_events_clean WHERE event_name = 'macro_beta_view'         AND event_ts BETWEEN p_from AND p_to),
        'ran',             (SELECT count(DISTINCT user_id) FROM public.usage_events_clean WHERE event_name = 'macro_beta_run_success'  AND event_ts BETWEEN p_from AND p_to),
        'drilled',         (SELECT count(DISTINCT user_id) FROM public.usage_events_clean WHERE event_name = 'macro_beta_drill_down'   AND event_ts BETWEEN p_from AND p_to),
        'saved',           (SELECT count(DISTINCT user_id) FROM public.macro_beta_saved_analyses                                       WHERE created_at BETWEEN p_from AND p_to),
        'upgrade_clicked', (SELECT count(DISTINCT user_id) FROM public.usage_events_clean WHERE event_name = 'macro_beta_upgrade_click' AND event_ts BETWEEN p_from AND p_to)
      )
    ),

    -- ===== Paywall v2 (period-filtered, dedup: macro_beta_upgrade_click removed from unique_clicked) =====
    'paywall_v2_summary', (
      SELECT jsonb_build_object(
        'credit_exhausted_shown',    (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'credit_exhausted_paywall_shown'   AND event_ts BETWEEN p_from AND p_to),
        'credit_exhausted_checkout', (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'credit_exhausted_checkout_start'  AND event_ts BETWEEN p_from AND p_to),
        'teaser_views',              (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'paywall_teaser_view'              AND event_ts BETWEEN p_from AND p_to),
        'teaser_cta_clicks',         (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'paywall_teaser_cta_click'         AND event_ts BETWEEN p_from AND p_to),
        'teaser_ticker_searches',    (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'paywall_teaser_ticker_search'     AND event_ts BETWEEN p_from AND p_to),
        'teaser_portfolio_detected', (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'paywall_teaser_portfolio_detected' AND event_ts BETWEEN p_from AND p_to),
        'hint_shown',                (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'paywall_hint_shown'               AND event_ts BETWEEN p_from AND p_to),
        'export_paywall_shown',      (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'export_paywall_shown'             AND event_ts BETWEEN p_from AND p_to),
        'passive_clicks',            (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'passive_paywall_click'            AND event_ts BETWEEN p_from AND p_to),
        'unique_users_blocked',      (SELECT count(DISTINCT user_id) FROM public.usage_events_clean WHERE event_name IN (
          'credit_exhausted_paywall_shown','paywall_teaser_view','paywall_hint_shown',
          'export_paywall_shown','passive_paywall_click'
        ) AND event_ts BETWEEN p_from AND p_to)
      )
    ),
    'paywall_v2_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
          count(*) FILTER (WHERE event_name = 'credit_exhausted_paywall_shown') AS credit_exhausted,
          count(*) FILTER (WHERE event_name = 'paywall_teaser_view') AS teaser_views,
          count(*) FILTER (WHERE event_name = 'paywall_hint_shown') AS hints,
          count(*) FILTER (WHERE event_name = 'export_paywall_shown') AS export_paywalls,
          count(*) FILTER (WHERE event_name = 'passive_paywall_click') AS passive_clicks,
          count(DISTINCT user_id) AS unique_users
        FROM public.usage_events_clean
        WHERE event_name IN (
          'credit_exhausted_paywall_shown','paywall_teaser_view','paywall_hint_shown',
          'export_paywall_shown','passive_paywall_click'
        )
          AND event_ts BETWEEN p_from AND p_to
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'paywall_v2_funnel', (
      SELECT jsonb_build_object(
        'teaser_views',          (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'paywall_teaser_view'              AND event_ts BETWEEN p_from AND p_to),
        'teaser_cta_clicks',     (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'paywall_teaser_cta_click'         AND event_ts BETWEEN p_from AND p_to),
        'credit_checkout_start', (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'credit_exhausted_checkout_start'  AND event_ts BETWEEN p_from AND p_to),
        'unique_blocked',        (SELECT count(DISTINCT user_id) FROM public.usage_events_clean WHERE event_name IN (
          'credit_exhausted_paywall_shown','paywall_teaser_view','paywall_hint_shown','export_paywall_shown'
        ) AND event_ts BETWEEN p_from AND p_to),
        'unique_clicked',        (SELECT count(DISTINCT user_id) FROM public.usage_events_clean WHERE event_name IN (
          'paywall_teaser_cta_click','passive_paywall_click','credit_exhausted_checkout_start'
        ) AND event_ts BETWEEN p_from AND p_to)
      )
    ),

    -- ===== Empty portfolio funnel (period-filtered) =====
    'empty_portfolio_funnel', (
      SELECT jsonb_build_object(
        'banner_views',         (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'empty_portfolio_banner_view'              AND event_ts BETWEEN p_from AND p_to),
        'cta_clicks',           (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'empty_portfolio_banner_cta_click'         AND event_ts BETWEEN p_from AND p_to),
        'imports_confirmed',    (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'empty_portfolio_banner_import_confirmed' AND event_ts BETWEEN p_from AND p_to),
        'photo_imports_success',(SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'portfolio_photo_import_success'           AND event_ts BETWEEN p_from AND p_to),
        'photo_imports_error',  (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'portfolio_photo_import_error'             AND event_ts BETWEEN p_from AND p_to),
        'unique_users',         (SELECT count(DISTINCT user_id) FROM public.usage_events_clean WHERE event_name IN (
          'empty_portfolio_banner_view','empty_portfolio_banner_cta_click','empty_portfolio_banner_import_confirmed',
          'portfolio_photo_import_success','portfolio_photo_import_error'
        ) AND event_ts BETWEEN p_from AND p_to)
      )
    ),

    -- ===== Companion =====
    'companion_messages_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               count(*) AS messages,
               count(DISTINCT user_id) AS unique_users
        FROM public.usage_events_clean
        WHERE event_name = 'companion_message_sent'
          AND event_ts BETWEEN p_from AND p_to
        GROUP BY day ORDER BY day ASC
      ) t
    ),

    -- ===== ValuAI save/share =====
    'valuai_save_share_summary', (
      SELECT jsonb_build_object(
        'analyses_started',  (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'valuai_analysis_start'    AND event_ts BETWEEN p_from AND p_to),
        'analyses_completed',(SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'valuai_analysis_complete' AND event_ts BETWEEN p_from AND p_to),
        'saves',             (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'valuai_save'              AND event_ts BETWEEN p_from AND p_to),
        'shares',            (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'valuai_share'             AND event_ts BETWEEN p_from AND p_to),
        'shared_loads',      (SELECT count(*) FROM public.usage_events_clean WHERE event_name = 'valuai_load_shared'       AND event_ts BETWEEN p_from AND p_to),
        'unique_savers',     (SELECT count(DISTINCT user_id) FROM public.usage_events_clean WHERE event_name = 'valuai_save'  AND event_ts BETWEEN p_from AND p_to),
        'unique_sharers',    (SELECT count(DISTINCT user_id) FROM public.usage_events_clean WHERE event_name = 'valuai_share' AND event_ts BETWEEN p_from AND p_to)
      )
    ),

    -- ===== Lifetime feature usage — derived from usage_events.feature column =====
    -- Source of truth: usage_events.feature (consistent: 13 macro_beta users vs 5 in
    -- public.lifetime_feature_usage table). Replaces dependency on the broken rollup table.
    'lifetime_feature_usage_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT feature,
               count(*) AS total_uses,
               count(DISTINCT user_id) AS unique_users,
               max(event_ts) AS last_used_at
        FROM public.usage_events_clean
        WHERE feature IN (
          'valuai','validador','qualitativo','macro_beta','optimizer',
          'portfolio_ianalise','portfolio_backtest','portfolio_macro_verdict'
        )
          AND user_id IS NOT NULL
          AND event_ts BETWEEN p_from AND p_to
        GROUP BY feature
        ORDER BY total_uses DESC
      ) t
    ),
    'lifetime_feature_top_users', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT ue.user_id,
               u.email,
               count(*) AS total_uses,
               count(DISTINCT ue.feature) AS features_used,
               array_agg(DISTINCT ue.feature ORDER BY ue.feature) AS features,
               max(ue.event_ts) AS last_used_at
        FROM public.usage_events_clean ue
        LEFT JOIN auth.users u ON u.id = ue.user_id
        WHERE ue.feature IN (
          'valuai','validador','qualitativo','macro_beta','optimizer',
          'portfolio_ianalise','portfolio_backtest','portfolio_macro_verdict'
        )
          AND ue.user_id IS NOT NULL
          AND ue.event_ts BETWEEN p_from AND p_to
        GROUP BY ue.user_id, u.email
        ORDER BY total_uses DESC, last_used_at DESC
        LIMIT 50
      ) t
    )
  );

  RETURN result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_analytics_data_bh_extras_v2(timestamptz, timestamptz)
  TO anon, authenticated, service_role;
