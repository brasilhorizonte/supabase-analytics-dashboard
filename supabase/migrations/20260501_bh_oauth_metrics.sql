-- ============================================================================
-- 20260501_bh_oauth_metrics.sql
-- Nova RPC additiva: get_analytics_data_bh_oauth()
-- Tracking de adocao do login Google OAuth (habilitado em 2026-04-30).
-- 3 secoes daily que respeitam o filtro temporal global do frontend.
-- Aplicar no projeto: brasilhorizonte (dawvgbopyemcayavcatd)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_analytics_data_bh_oauth()
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
        GROUP BY 1, 2, 3
        ORDER BY 1 ASC
      ) t
    )

  ) INTO result;

  RETURN result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_analytics_data_bh_oauth() TO anon, authenticated, service_role;
