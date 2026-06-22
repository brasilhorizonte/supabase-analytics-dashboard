-- BH Engagement — Ticker Analytics v3 (2026-05-27)
--
-- Reformulação das 6 seções de ticker da aba Engajamento iAções. Mudanças vs
-- get_analytics_data_v2():
--   1. Top N de `ticker_trend_daily` agora é calculado dentro do período
--      [p_from, p_to] (antes era all-time, fazendo os tickers parecerem
--      "estáticos" quando o usuário trocava de janela).
--   2. `ticker_ranking`, `user_ticker_usage`, `user_ticker_detail` agora
--      respeitam (p_from, p_to). Antes eram all-time, ignorando o filtro global.
--   3. `feature_usage_trend` deixa de exigir `ticker IS NOT NULL` — features
--      sem ticker (Macro Beta, Optimizer) voltam a aparecer. Retorna AMBOS
--      `cnt` (rodadas) e `unique_users` para o frontend escolher via toggle.
--   4. `p_include_admins boolean DEFAULT false` — padrão Airton v2.3. Filtra
--      admins via `profiles.is_admin` (NOT EXISTS) quando false.
--   5. `p_tickers text[] DEFAULT NULL` — multi-select. Quando não-nulo, ignora
--      top N e devolve só esses tickers em `ticker_trend_daily`. Quando nulo,
--      calcula top N dinâmico + linha 'Outros'.
--   6. `p_top_n int DEFAULT 30` — parametrizável.
--
-- A v2 (get_analytics_data_v2) NÃO é alterada — apenas deixa de ser fonte
-- dessas 6 seções no frontend. Mudança puramente additive.

DROP FUNCTION IF EXISTS public.get_analytics_data_bh_tickers_v3(
  timestamptz, timestamptz, boolean, text[], int
);

CREATE OR REPLACE FUNCTION public.get_analytics_data_bh_tickers_v3(
  p_from           timestamptz DEFAULT (now() - interval '30 days'),
  p_to             timestamptz DEFAULT now(),
  p_include_admins boolean     DEFAULT false,
  p_tickers        text[]      DEFAULT NULL,
  p_top_n          int         DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
  v_has_filter boolean := (p_tickers IS NOT NULL AND array_length(p_tickers, 1) > 0);
BEGIN
  WITH
  -- ─── Base: eventos com ticker, dentro do período, admin toggle ──────────
  ev AS (
    SELECT u.*
    FROM public.usage_events u
    WHERE event_ts BETWEEN p_from AND p_to
      AND (
        p_include_admins
        OR NOT EXISTS (
          SELECT 1 FROM public.profiles p
          WHERE p.user_id = u.user_id AND p.is_admin = true
        )
      )
  ),
  ev_ticker AS (
    SELECT * FROM ev WHERE ticker IS NOT NULL AND ticker != ''
  ),
  -- ─── Top N tickers DENTRO do período ─────────────────────────────────────
  -- Bug v2: calculava all-time. v3: respeita p_from/p_to.
  top_tickers AS (
    SELECT ticker
    FROM ev_ticker
    GROUP BY ticker
    ORDER BY count(*) DESC
    LIMIT p_top_n
  ),
  -- ─── ticker_by_feature ───────────────────────────────────────────────────
  ticker_by_feature AS (
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) AS data
    FROM (
      SELECT feature,
             ticker,
             count(*) AS cnt,
             count(DISTINCT user_id) AS unique_users
      FROM ev_ticker
      WHERE feature IS NOT NULL
      GROUP BY feature, ticker
      ORDER BY feature, cnt DESC
    ) t
  ),
  -- ─── ticker_trend_daily ──────────────────────────────────────────────────
  -- Modo A (sem filtro): top N dinâmico + linha 'Outros'.
  -- Modo B (com filtro): só os tickers passados em p_tickers, sem 'Outros'.
  ticker_trend_daily AS (
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) AS data
    FROM (
      SELECT day, ticker, cnt FROM (
        -- Modo A: top N tickers do período
        SELECT date_trunc('day', e.event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               e.ticker,
               count(*) AS cnt
        FROM ev_ticker e
        WHERE NOT v_has_filter
          AND e.ticker IN (SELECT ticker FROM top_tickers)
        GROUP BY day, e.ticker
        UNION ALL
        -- Modo A: agregado 'Outros'
        SELECT date_trunc('day', e.event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               'Outros' AS ticker,
               count(*) AS cnt
        FROM ev_ticker e
        WHERE NOT v_has_filter
          AND e.ticker NOT IN (SELECT ticker FROM top_tickers)
        GROUP BY day
        UNION ALL
        -- Modo B: só os tickers do filtro
        SELECT date_trunc('day', e.event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
               e.ticker,
               count(*) AS cnt
        FROM ev_ticker e
        WHERE v_has_filter
          AND e.ticker = ANY(p_tickers)
        GROUP BY day, e.ticker
      ) sub
      ORDER BY day ASC
    ) t
  ),
  -- ─── feature_usage_trend ─────────────────────────────────────────────────
  -- v3: NÃO exige ticker IS NOT NULL — features puras (macro_beta, optimizer)
  -- também aparecem. Retorna cnt + unique_users; frontend escolhe via toggle.
  feature_usage_trend AS (
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) AS data
    FROM (
      SELECT date_trunc('day', event_ts AT TIME ZONE 'America/Sao_Paulo')::date AS day,
             feature,
             count(*) AS cnt,
             count(DISTINCT user_id) AS unique_users,
             count(DISTINCT ticker) FILTER (WHERE ticker IS NOT NULL AND ticker != '') AS unique_tickers
      FROM ev
      WHERE feature IS NOT NULL
      GROUP BY day, feature
      ORDER BY day ASC
    ) t
  ),
  -- ─── ticker_ranking ──────────────────────────────────────────────────────
  -- v3: filtra por período (era all-time).
  ticker_ranking AS (
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) AS data
    FROM (
      SELECT ticker,
             count(*) AS cnt,
             count(DISTINCT user_id) AS unique_users
      FROM ev_ticker
      GROUP BY ticker
      ORDER BY cnt DESC
      LIMIT 20
    ) t
  ),
  -- ─── user_ticker_usage ───────────────────────────────────────────────────
  -- v3: filtra por período, limite 200 (drill-down precisa de mais linhas).
  user_ticker_usage AS (
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) AS data
    FROM (
      SELECT
        e.user_id,
        coalesce(u.email, e.user_id::text) AS email,
        COUNT(*)                            AS total_queries,
        COUNT(DISTINCT e.ticker)            AS unique_tickers,
        MODE() WITHIN GROUP (ORDER BY e.ticker)  AS top_ticker,
        MODE() WITHIN GROUP (ORDER BY e.feature) AS top_feature,
        MAX(e.event_ts)                     AS last_activity
      FROM ev_ticker e
      LEFT JOIN auth.users u ON u.id = e.user_id
      WHERE e.user_id IS NOT NULL
      GROUP BY e.user_id, u.email
      ORDER BY total_queries DESC
      LIMIT 200
    ) t
  ),
  -- ─── user_ticker_detail ──────────────────────────────────────────────────
  -- v3: filtra por período. Frontend agrupa por user_id no drill-down.
  -- Limite 5000 linhas para evitar payload absurda em janelas grandes.
  user_ticker_detail AS (
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) AS data
    FROM (
      SELECT
        e.user_id,
        e.ticker,
        e.feature,
        COUNT(*) AS cnt
      FROM ev_ticker e
      WHERE e.user_id IS NOT NULL AND e.feature IS NOT NULL
      GROUP BY e.user_id, e.ticker, e.feature
      ORDER BY cnt DESC
      LIMIT 5000
    ) t
  )

  SELECT jsonb_build_object(
    'ticker_by_feature',   (SELECT data FROM ticker_by_feature),
    'ticker_trend_daily',  (SELECT data FROM ticker_trend_daily),
    'feature_usage_trend', (SELECT data FROM feature_usage_trend),
    'ticker_ranking',      (SELECT data FROM ticker_ranking),
    'user_ticker_usage',   (SELECT data FROM user_ticker_usage),
    'user_ticker_detail',  (SELECT data FROM user_ticker_detail),
    'meta', jsonb_build_object(
      'from',            p_from,
      'to',              p_to,
      'include_admins',  p_include_admins,
      'top_n',           p_top_n,
      'tickers_filter',  p_tickers,
      'has_ticker_filter', v_has_filter,
      'source',          'usage_events',
      'rpc_version',     'bh_tickers_v3_20260527'
    )
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

-- Hardening 2026-05-12: não conceder EXECUTE para anon.
-- Edge Function usa service_role; usuários autenticados via PostgREST direto
-- (não há esse caminho hoje, mas mantém aberto para futuro).
GRANT EXECUTE ON FUNCTION public.get_analytics_data_bh_tickers_v3(
  timestamptz, timestamptz, boolean, text[], int
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
