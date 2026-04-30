-- ============================================================================
-- 20260430_iacoes_daily_breakdowns.sql
-- ============================================================================
-- Adiciona nova RPC additiva get_analytics_data_iacoes_daily() retornando
-- versoes _daily de 8 secoes que hoje sao snapshots all-time. Permite que o
-- frontend filtre todas as visualizacoes da aba Landing iAcoes pelo periodo
-- global (globalFilters.from / globalFilters.to).
--
-- Padrao additivo (mesmo de 20260427_bh_usage_events_utm.sql) -- nao toca em
-- get_analytics_data nem em get_analytics_data_bh_extras.
--
-- Aplicar no projeto: brasilhorizonte (dawvgbopyemcayavcatd)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_analytics_data_iacoes_daily()
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
        WHERE device_type IS NOT NULL
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
        WHERE browser IS NOT NULL
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
        WHERE os IS NOT NULL
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
        WHERE utm_source IS NOT NULL
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
        WHERE event_type = 'cta_click'
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
        WHERE event_type = 'cta_click'
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
          WHERE event_name = 'session_start' AND referrer ILIKE '%iacoes%'
        )
        SELECT date_trunc('day', ue.event_ts AT TIME ZONE 'America/Sao_Paulo')::date as day,
               extract(hour from ue.event_ts AT TIME ZONE 'America/Sao_Paulo')::int as hour,
               extract(dow from ue.event_ts AT TIME ZONE 'America/Sao_Paulo')::int as dow,
               count(*) FILTER (WHERE ue.event_name = 'session_start' AND ue.referrer ILIKE '%iacoes%') as sessions,
               count(*) FILTER (WHERE ue.event_name = 'auth_login') as logins,
               count(*) FILTER (WHERE ue.event_name = 'paywall_block') as paywall,
               count(*) FILTER (WHERE ue.event_name = 'payment_succeeded') as payments
        FROM public.usage_events ue
        WHERE ue.session_id IN (SELECT session_id FROM iacoes_sessions)
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
          WHERE event_name = 'session_start'
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
        LEFT JOIN public.usage_events ue_pay
               ON ue_pay.session_id = ss.session_id
              AND ue_pay.event_name = 'paywall_block'
        GROUP BY ss.day, ss.source
        ORDER BY ss.day ASC
      ) t
    )

  ) INTO result;

  RETURN result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_analytics_data_iacoes_daily() TO anon, authenticated, service_role;
