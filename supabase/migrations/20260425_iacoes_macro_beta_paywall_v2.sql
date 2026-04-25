-- Migration: iAcoes (BH) — Macro Beta + Paywall v2 + CVM interactions + portfolio v2
-- Date: 2026-04-25
-- Adds tracking for newly-launched features: Macro Beta (2026-04-23), paywall v2
-- (credit_exhausted, teaser, hint, export), CVM interactions (doc_expand, pdf_click,
-- telegram_cta), empty portfolio funnel + photo imports, companion messages,
-- valuai save/share, and lifetime feature usage rollup. Expands existing
-- portfolio_activity_daily and cvm_activity_daily.
-- Project: brasilhorizonte (dawvgbopyemcayavcatd)

CREATE OR REPLACE FUNCTION public.get_analytics_data_bh_extras()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
BEGIN
  result := jsonb_build_object(
    -- ===== Existing sections (preserved) =====
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
    ),
    'subscription_trials_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               count(*) AS trials
        FROM public.usage_events WHERE event_name = 'trial_start'
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
    -- Expanded portfolio_activity_daily — adds delete, ianalise, photo imports, banner views
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
          count(*) FILTER (WHERE event_name = 'cvm_filter_portfolio_apply') AS cvm_filters,
          count(*) FILTER (WHERE event_name = 'portfolio_photo_import_success') AS photo_imports,
          count(DISTINCT user_id) FILTER (WHERE event_name LIKE 'portfolio%' OR event_name LIKE '%filter_portfolio%') AS unique_users
        FROM public.usage_events
        WHERE event_name IN (
          'portfolio_add_asset','portfolio_remove_asset','portfolio_save','portfolio_load',
          'portfolio_delete','portfolio_ianalise_run','content_filter_portfolio_apply',
          'cvm_filter_portfolio_apply','portfolio_photo_import_success'
        )
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
    -- Expanded cvm_activity_daily — adds pdf_click, telegram_cta interactions, type_toggle
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
        FROM public.usage_events
        WHERE event_name IN (
          'cvm_doc_expand','cvm_filter_portfolio_apply','cvm_pdf_click',
          'cvm_telegram_cta_click','cvm_telegram_cta_dismiss','cvm_filter_type_toggle'
        )
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
    ),
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
               rule_type, count(*) AS cnt
        FROM public.alert_rules GROUP BY day, rule_type ORDER BY day ASC
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
    'email_log_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', created_at AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               email_type, count(*) AS sent,
               count(*) FILTER (WHERE status != 'sent' AND status IS NOT NULL) AS failed
        FROM public.email_log GROUP BY day, email_type ORDER BY day ASC
      ) t
    ),
    'email_log_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT email_type, count(*) AS total,
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
               category, count(*) AS sent
        FROM public.whatsapp_log GROUP BY day, category ORDER BY day ASC
      ) t
    ),
    'whatsapp_log_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT category, count(*) AS total, count(DISTINCT recipient_user_id) AS unique_recipients
        FROM public.whatsapp_log GROUP BY category ORDER BY total DESC
      ) t
    ),

    -- ===== NEW SECTIONS (2026-04-25) =====

    -- Macro Beta feature (launched 2026-04-23)
    'macro_beta_overview', (
      SELECT jsonb_build_object(
        'views', (SELECT count(*) FROM public.usage_events WHERE event_name = 'macro_beta_view'),
        'runs_success', (SELECT count(*) FROM public.usage_events WHERE event_name = 'macro_beta_run_success'),
        'runs_error', (SELECT count(*) FROM public.usage_events WHERE event_name = 'macro_beta_run_error'),
        'verdicts_generated', (SELECT count(*) FROM public.usage_events WHERE event_name = 'macro_verdict_generated'),
        'drill_downs', (SELECT count(*) FROM public.usage_events WHERE event_name = 'macro_beta_drill_down'),
        'tooltip_opens', (SELECT count(*) FROM public.usage_events WHERE event_name = 'macro_beta_factor_tooltip_open'),
        'sort_changes', (SELECT count(*) FROM public.usage_events WHERE event_name = 'macro_beta_sort_change'),
        'upgrade_clicks', (SELECT count(*) FROM public.usage_events WHERE event_name = 'macro_beta_upgrade_click'),
        'coupon_copies', (SELECT count(*) FROM public.usage_events WHERE event_name = 'macro_beta_coupon_copied'),
        'unique_users', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name LIKE 'macro_%'),
        'saved_total', (SELECT count(*) FROM public.macro_beta_saved_analyses),
        'saved_unique_users', (SELECT count(DISTINCT user_id) FROM public.macro_beta_saved_analyses)
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
          count(DISTINCT user_id) FILTER (WHERE event_name LIKE 'macro_%') AS unique_users
        FROM public.usage_events
        WHERE event_name LIKE 'macro_%'
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'macro_beta_funnel', (
      SELECT jsonb_build_object(
        'viewed', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'macro_beta_view'),
        'ran', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'macro_beta_run_success'),
        'drilled', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'macro_beta_drill_down'),
        'saved', (SELECT count(DISTINCT user_id) FROM public.macro_beta_saved_analyses),
        'upgrade_clicked', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'macro_beta_upgrade_click')
      )
    ),

    -- Paywall v2 — new paywall touchpoints
    'paywall_v2_summary', (
      SELECT jsonb_build_object(
        'credit_exhausted_shown', (SELECT count(*) FROM public.usage_events WHERE event_name = 'credit_exhausted_paywall_shown'),
        'credit_exhausted_checkout', (SELECT count(*) FROM public.usage_events WHERE event_name = 'credit_exhausted_checkout_start'),
        'teaser_views', (SELECT count(*) FROM public.usage_events WHERE event_name = 'paywall_teaser_view'),
        'teaser_cta_clicks', (SELECT count(*) FROM public.usage_events WHERE event_name = 'paywall_teaser_cta_click'),
        'teaser_ticker_searches', (SELECT count(*) FROM public.usage_events WHERE event_name = 'paywall_teaser_ticker_search'),
        'teaser_portfolio_detected', (SELECT count(*) FROM public.usage_events WHERE event_name = 'paywall_teaser_portfolio_detected'),
        'hint_shown', (SELECT count(*) FROM public.usage_events WHERE event_name = 'paywall_hint_shown'),
        'export_paywall_shown', (SELECT count(*) FROM public.usage_events WHERE event_name = 'export_paywall_shown'),
        'passive_clicks', (SELECT count(*) FROM public.usage_events WHERE event_name = 'passive_paywall_click'),
        'unique_users_blocked', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name IN ('credit_exhausted_paywall_shown','paywall_teaser_view','paywall_hint_shown','export_paywall_shown','passive_paywall_click'))
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
        FROM public.usage_events
        WHERE event_name IN (
          'credit_exhausted_paywall_shown','paywall_teaser_view','paywall_hint_shown',
          'export_paywall_shown','passive_paywall_click'
        )
        GROUP BY day ORDER BY day ASC
      ) t
    ),
    'paywall_v2_funnel', (
      SELECT jsonb_build_object(
        'teaser_views', (SELECT count(*) FROM public.usage_events WHERE event_name = 'paywall_teaser_view'),
        'teaser_cta_clicks', (SELECT count(*) FROM public.usage_events WHERE event_name = 'paywall_teaser_cta_click'),
        'credit_checkout_start', (SELECT count(*) FROM public.usage_events WHERE event_name = 'credit_exhausted_checkout_start'),
        'unique_blocked', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name IN ('credit_exhausted_paywall_shown','paywall_teaser_view','paywall_hint_shown','export_paywall_shown')),
        'unique_clicked', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name IN ('paywall_teaser_cta_click','passive_paywall_click','credit_exhausted_checkout_start','macro_beta_upgrade_click'))
      )
    ),

    -- CVM interactions — new event types beyond doc_expand+filter_apply
    'cvm_interactions_summary', (
      SELECT jsonb_build_object(
        'doc_expands', (SELECT count(*) FROM public.usage_events WHERE event_name = 'cvm_doc_expand'),
        'pdf_clicks', (SELECT count(*) FROM public.usage_events WHERE event_name = 'cvm_pdf_click'),
        'filter_applies', (SELECT count(*) FROM public.usage_events WHERE event_name = 'cvm_filter_portfolio_apply'),
        'type_toggles', (SELECT count(*) FROM public.usage_events WHERE event_name = 'cvm_filter_type_toggle'),
        'telegram_cta_clicks', (SELECT count(*) FROM public.usage_events WHERE event_name = 'cvm_telegram_cta_click'),
        'telegram_cta_dismisses', (SELECT count(*) FROM public.usage_events WHERE event_name = 'cvm_telegram_cta_dismiss'),
        'unique_users', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name LIKE 'cvm_%')
      )
    ),

    -- Empty portfolio funnel — onboarding signal
    'empty_portfolio_funnel', (
      SELECT jsonb_build_object(
        'banner_views', (SELECT count(*) FROM public.usage_events WHERE event_name = 'empty_portfolio_banner_view'),
        'cta_clicks', (SELECT count(*) FROM public.usage_events WHERE event_name = 'empty_portfolio_banner_cta_click'),
        'imports_confirmed', (SELECT count(*) FROM public.usage_events WHERE event_name = 'empty_portfolio_banner_import_confirmed'),
        'photo_imports_success', (SELECT count(*) FROM public.usage_events WHERE event_name = 'portfolio_photo_import_success'),
        'photo_imports_error', (SELECT count(*) FROM public.usage_events WHERE event_name = 'portfolio_photo_import_error'),
        'unique_users', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name LIKE 'empty_portfolio%' OR event_name LIKE 'portfolio_photo_import%')
      )
    ),

    -- Companion (IAnalista) chat usage
    'companion_messages_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               count(*) AS messages,
               count(DISTINCT user_id) AS unique_users
        FROM public.usage_events
        WHERE event_name = 'companion_message_sent'
        GROUP BY day ORDER BY day ASC
      ) t
    ),

    -- Valuai save/share metrics (newly tracked)
    'valuai_save_share_summary', (
      SELECT jsonb_build_object(
        'analyses_started', (SELECT count(*) FROM public.usage_events WHERE event_name = 'valuai_analysis_start'),
        'analyses_completed', (SELECT count(*) FROM public.usage_events WHERE event_name = 'valuai_analysis_complete'),
        'saves', (SELECT count(*) FROM public.usage_events WHERE event_name = 'valuai_save'),
        'shares', (SELECT count(*) FROM public.usage_events WHERE event_name = 'valuai_share'),
        'shared_loads', (SELECT count(*) FROM public.usage_events WHERE event_name = 'valuai_load_shared'),
        'unique_savers', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'valuai_save'),
        'unique_sharers', (SELECT count(DISTINCT user_id) FROM public.usage_events WHERE event_name = 'valuai_share')
      )
    ),

    -- Lifetime feature usage rollup (gated AI features)
    'lifetime_feature_usage_summary', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT feature,
               count(*) AS total_uses,
               count(DISTINCT user_id) AS unique_users,
               max(used_at) AS last_used_at
        FROM public.lifetime_feature_usage
        GROUP BY feature ORDER BY total_uses DESC
      ) t
    ),
    'lifetime_feature_top_users', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT lfu.user_id,
               u.email,
               count(*) AS total_uses,
               count(DISTINCT lfu.feature) AS features_used,
               max(lfu.used_at) AS last_used_at
        FROM public.lifetime_feature_usage lfu
        LEFT JOIN auth.users u ON u.id = lfu.user_id
        GROUP BY lfu.user_id, u.email
        ORDER BY total_uses DESC
        LIMIT 20
      ) t
    )
  );
  RETURN result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_analytics_data_bh_extras() TO anon, authenticated, service_role;
