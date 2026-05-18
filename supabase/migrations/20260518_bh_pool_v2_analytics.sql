-- ============================================================================
-- Sprint TELEMETRY B1+B2+B3 (2026-05-18): visibilidade do Paywall V2+α no
-- dashboard Mary. RPC AdITIVA — não toca v2 existente, complementa.
--
-- Contexto: em 2026-05-14 o produto Brasil Horizonte migrou de paywall
-- "lifetime" (lifetime_feature_usage) para "daily refill" (daily_feature_usage).
-- 1 análise/dia COMPARTILHADA entre 7 features one-shot + AIrton 5 tools/dia
-- janela móvel. Dashboard ficou cego entre 14/05 e 18/05.
--
-- Sources:
--   - daily_feature_usage (pool V2: 1 análise/dia entre 7 features)
--   - usage_events_clean (companion_tool_call eventos pra histograma B2)
--
-- Aplicada via MCP no projeto BH em 2026-05-18 (registry é fonte da verdade).
-- Este arquivo local é apenas espelho de documentação seguindo pattern do repo.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_analytics_data_bh_pool_v2(
  p_from timestamptz DEFAULT now() - interval '30 days',
  p_to   timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  result jsonb;
  today_brt date := (now() AT TIME ZONE 'America/Sao_Paulo')::date;
BEGIN
  -- Auth guard: service_role bypassa, authenticated tem que ser admin
  IF auth.role() <> 'service_role'
     AND NOT public.is_admin(auth.uid())
  THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  result := jsonb_build_object(
    -- B1.1: Pool V2 overview — KPIs agregados (today BRT + período)
    'pool_v2_overview', (
      SELECT jsonb_build_object(
        'consumes_today',         COUNT(*) FILTER (
          WHERE (last_used_at AT TIME ZONE 'America/Sao_Paulo')::date = today_brt
        ),
        'unique_users_today',     COUNT(DISTINCT user_id) FILTER (
          WHERE (last_used_at AT TIME ZONE 'America/Sao_Paulo')::date = today_brt
        ),
        'top_feature_today',      (
          SELECT last_feature
          FROM public.daily_feature_usage
          WHERE (last_used_at AT TIME ZONE 'America/Sao_Paulo')::date = today_brt
          GROUP BY last_feature
          ORDER BY COUNT(*) DESC
          LIMIT 1
        ),
        'consumes_period',        COUNT(*) FILTER (
          WHERE last_used_at BETWEEN p_from AND p_to
        ),
        'unique_users_period',    COUNT(DISTINCT user_id) FILTER (
          WHERE last_used_at BETWEEN p_from AND p_to
        ),
        'top_feature_period',     (
          SELECT last_feature
          FROM public.daily_feature_usage
          WHERE last_used_at BETWEEN p_from AND p_to
          GROUP BY last_feature
          ORDER BY COUNT(*) DESC
          LIMIT 1
        ),
        'adoption_pct_period',    (
          SELECT ROUND(
            100.0 * COUNT(DISTINCT dfu.user_id)::numeric
                  / NULLIF((SELECT COUNT(*) FROM public.profiles WHERE NOT is_admin), 0),
            2
          )
          FROM public.daily_feature_usage dfu
          WHERE dfu.last_used_at BETWEEN p_from AND p_to
        )
      )
      FROM public.daily_feature_usage
    ),

    -- B1.2: Pool V2 daily — série temporal de uso
    'pool_v2_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          base.day_brt,
          base.consumes,
          base.unique_users,
          (
            SELECT last_feature
            FROM public.daily_feature_usage d2
            WHERE (d2.last_used_at AT TIME ZONE 'America/Sao_Paulo')::date = base.day_brt
            GROUP BY last_feature
            ORDER BY COUNT(*) DESC
            LIMIT 1
          ) AS top_feature
        FROM (
          SELECT
            (last_used_at AT TIME ZONE 'America/Sao_Paulo')::date AS day_brt,
            COUNT(*) AS consumes,
            COUNT(DISTINCT user_id) AS unique_users
          FROM public.daily_feature_usage
          WHERE last_used_at BETWEEN p_from AND p_to
          GROUP BY 1
        ) base
        ORDER BY base.day_brt
      ) t
    ),

    -- B1.3: Distribuição das 7 features do pool no período
    'pool_v2_feature_distribution', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          last_feature AS feature,
          COUNT(*) AS total_consumes,
          COUNT(DISTINCT user_id) AS unique_users,
          ROUND(
            100.0 * COUNT(*)::numeric / NULLIF(SUM(COUNT(*)) OVER (), 0),
            2
          ) AS share_pct
        FROM public.daily_feature_usage
        WHERE last_used_at BETWEEN p_from AND p_to
        GROUP BY last_feature
        ORDER BY total_consumes DESC
      ) t
    ),

    -- B2: Histograma de tool calls AIrton por user/dia (janela móvel V2+α)
    'airton_tool_daily_histogram', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH user_day_count AS (
          SELECT
            user_id,
            (event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day_brt,
            COUNT(*) AS tools_in_day
          FROM public.usage_events_clean
          WHERE event_name = 'companion_tool_call'
            AND event_ts BETWEEN p_from AND p_to
            AND user_id IS NOT NULL
          GROUP BY 1, 2
        )
        SELECT
          CASE
            WHEN tools_in_day BETWEEN 1 AND 2 THEN '1-2'
            WHEN tools_in_day BETWEEN 3 AND 4 THEN '3-4'
            WHEN tools_in_day >= 5             THEN '5+'
          END AS bucket,
          COUNT(*) AS user_days,
          COUNT(DISTINCT user_id) AS unique_users
        FROM user_day_count
        GROUP BY 1
        ORDER BY 1
      ) t
    ),

    -- B3: Habit-loop retention — KPI canônico Sprint NEW-PAYWALL-V2
    'pool_v2_retention', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        WITH user_first AS (
          SELECT user_id, MIN((last_used_at AT TIME ZONE 'America/Sao_Paulo')::date) AS first_day
          FROM public.daily_feature_usage
          WHERE last_used_at BETWEEN p_from AND p_to
          GROUP BY 1
        ),
        cohort_days AS (
          SELECT first_day AS cohort_date, COUNT(*) AS cohort_size
          FROM user_first
          GROUP BY 1
        ),
        retention AS (
          SELECT
            uf.first_day AS cohort_date,
            COUNT(DISTINCT dfu.user_id) FILTER (
              WHERE (dfu.last_used_at AT TIME ZONE 'America/Sao_Paulo')::date = uf.first_day + 1
            ) AS retained_d1,
            COUNT(DISTINCT dfu.user_id) FILTER (
              WHERE (dfu.last_used_at AT TIME ZONE 'America/Sao_Paulo')::date = uf.first_day + 7
            ) AS retained_d7,
            COUNT(DISTINCT dfu.user_id) FILTER (
              WHERE (dfu.last_used_at AT TIME ZONE 'America/Sao_Paulo')::date = uf.first_day + 30
            ) AS retained_d30
          FROM user_first uf
          LEFT JOIN public.daily_feature_usage dfu ON dfu.user_id = uf.user_id
          GROUP BY 1
        )
        SELECT
          c.cohort_date,
          c.cohort_size,
          r.retained_d1,
          ROUND(100.0 * r.retained_d1::numeric / NULLIF(c.cohort_size, 0), 2) AS retention_d1_pct,
          r.retained_d7,
          ROUND(100.0 * r.retained_d7::numeric / NULLIF(c.cohort_size, 0), 2) AS retention_d7_pct,
          r.retained_d30,
          ROUND(100.0 * r.retained_d30::numeric / NULLIF(c.cohort_size, 0), 2) AS retention_d30_pct
        FROM cohort_days c
        LEFT JOIN retention r USING (cohort_date)
        ORDER BY c.cohort_date
      ) t
    ),

    'meta_pool_v2', jsonb_build_object(
      'from', p_from,
      'to', p_to,
      'today_brt', today_brt,
      'source', 'daily_feature_usage + usage_events_clean (admin-filtered)'
    )
  );

  RETURN result;
END;
$function$;

COMMENT ON FUNCTION public.get_analytics_data_bh_pool_v2(timestamptz, timestamptz) IS
'Sprint TELEMETRY B1+B2+B3 (2026-05-18): dashboard Mary lê pool V2 daily refill.
Substitui visibilidade que estava cega após cutover 14/05 (lifetime_feature_usage virou daily_feature_usage).
Aditiva — não toca get_analytics_data_bh_extras_v2.
Auth guard: service_role + admin.';

GRANT EXECUTE ON FUNCTION public.get_analytics_data_bh_pool_v2(timestamptz, timestamptz)
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
