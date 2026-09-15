-- ============================================================================
-- 20260914_iacoes_landing_v3.sql
-- Landing iAcoes: modelo por sessao (atribuicao first-touch) + scroll depth.
--
-- Motivacao:
--  1. As secoes existentes (iacoes_*_daily) sao contagens de pageview por
--     dimensao. Nao existe nenhuma metrica de QUALIDADE da sessao (rejeicao,
--     profundidade de leitura, paginas por sessao) e cada dimensao vem numa
--     chave propria -- o frontend precisa de um bloco de codigo por dimensao.
--  2. Os eventos scroll_25/50/75/100 (30k linhas em iacoes_page_views) nunca
--     foram consumidos pelo dashboard. Sao o unico sinal real de engajamento
--     da landing.
--
-- Modelo: cada sessao recebe os atributos do seu PRIMEIRO evento (first-touch)
-- e as metricas agregadas de toda a sessao. `iacoes_dim_daily` e uma tabela
-- tidy (day, dim, value, metricas) -- uma linha por dimensao/valor/dia, o que
-- permite um unico explorador generico no frontend em vez de N graficos fixos.
--
-- Nota sobre duracao: o session_id da landing persiste por semanas (p99 = 16h,
-- max = 21 dias). Media crua nao significa nada, entao `dur_sum` soma a duracao
-- LIMITADA A 30 MIN por sessao -- a UI rotula a coluna como "cap 30min".
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_analytics_data_iacoes_v3(
  p_from timestamptz DEFAULT now() - interval '30 days',
  p_to   timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '30s'
AS $function$
DECLARE
  result jsonb;
BEGIN
  WITH pv AS (
    SELECT * FROM public.iacoes_page_views_human
    WHERE created_at BETWEEN p_from AND p_to
  ),
  -- Metricas agregadas da sessao inteira
  sess AS (
    SELECT session_id,
           min(created_at) AS first_seen,
           max(created_at) AS last_seen,
           count(*) FILTER (WHERE event_type = 'pageview' OR event_type IS NULL) AS pageviews,
           count(*) FILTER (WHERE event_type = 'cta_click') AS cta_clicks,
           count(DISTINCT page_path) AS pages,
           max(CASE event_type WHEN 'scroll_100' THEN 100 WHEN 'scroll_75' THEN 75
                               WHEN 'scroll_50' THEN 50  WHEN 'scroll_25' THEN 25
                               ELSE 0 END) AS max_scroll
    FROM pv GROUP BY session_id
  ),
  -- Atributos do primeiro evento da sessao (first-touch attribution)
  fp AS (
    SELECT DISTINCT ON (session_id)
           session_id, page_path, referrer, utm_source, utm_medium, utm_campaign,
           device_type, browser, os, source_hint, click_id_source, created_at
    FROM pv ORDER BY session_id, created_at, id
  ),
  sd AS (
    SELECT s.session_id,
           (f.created_at AT TIME ZONE 'America/Sao_Paulo')::date AS day,
           s.pageviews, s.cta_clicks, s.pages, s.max_scroll,
           LEAST(GREATEST(extract(epoch FROM (s.last_seen - s.first_seen))::int, 0), 1800) AS dur_capped,
           GREATEST(extract(epoch FROM (s.last_seen - s.first_seen))::int, 0) AS dur_raw,
           -- Rejeicao: 1 pageview, nenhum CTA e nao passou da metade da pagina
           (s.pageviews <= 1 AND s.cta_clicks = 0 AND s.max_scroll < 50) AS is_bounce,
           CASE
             WHEN f.referrer ILIKE '%google%' OR f.referrer ILIKE '%android-app://com.google%' THEN 'Google'
             WHEN f.referrer ILIKE '%bing%' THEN 'Bing'
             WHEN f.referrer ILIKE '%yahoo%' THEN 'Yahoo'
             WHEN f.referrer ILIKE '%brasilhorizonte%' OR f.referrer ILIKE '%iacoes%' THEN 'Interno'
             WHEN f.referrer ILIKE '%facebook%' OR f.referrer ILIKE '%fbclid%' THEN 'Facebook'
             WHEN f.referrer ILIKE '%instagram%' THEN 'Instagram'
             WHEN f.referrer ILIKE '%twitter%' OR f.referrer ILIKE '%://x.com%' OR f.referrer ILIKE '%://t.co/%' THEN 'Twitter/X'
             WHEN f.referrer ILIKE '%linkedin%' THEN 'LinkedIn'
             WHEN f.referrer ILIKE '%reddit%' THEN 'Reddit'
             WHEN f.referrer ILIKE '%youtube%' OR f.referrer ILIKE '%youtu.be%' THEN 'YouTube'
             WHEN f.referrer ILIKE '%whatsapp%' THEN 'WhatsApp'
             WHEN f.referrer ILIKE '%telegram%' OR f.referrer ILIKE '%t.me%' THEN 'Telegram'
             WHEN f.click_id_source = 'facebook' THEN 'Facebook (ads)'
             WHEN f.click_id_source = 'google_ads' THEN 'Google (ads)'
             WHEN f.click_id_source = 'tiktok' THEN 'TikTok (ads)'
             WHEN f.click_id_source = 'linkedin' THEN 'LinkedIn (ads)'
             WHEN f.click_id_source = 'twitter' THEN 'Twitter/X (ads)'
             WHEN f.click_id_source = 'microsoft_ads' THEN 'Bing (ads)'
             WHEN f.source_hint = 'facebook' THEN 'Facebook (app)'
             WHEN f.source_hint = 'instagram' THEN 'Instagram (app)'
             WHEN f.source_hint = 'linkedin' THEN 'LinkedIn (app)'
             WHEN f.source_hint = 'whatsapp' THEN 'WhatsApp (app)'
             WHEN f.source_hint = 'telegram' THEN 'Telegram (app)'
             WHEN f.source_hint = 'twitter' THEN 'Twitter/X (app)'
             WHEN f.referrer IS NOT NULL AND f.referrer <> '' THEN 'Outro'
             ELSE 'Direto'
           END AS fonte,
           coalesce(f.device_type, '(sem dado)')   AS device_type,
           coalesce(f.browser, '(sem dado)')       AS browser,
           coalesce(f.os, '(sem dado)')            AS os,
           coalesce(f.utm_source, '(sem utm)')     AS utm_source,
           coalesce(f.utm_medium, '(sem utm)')     AS utm_medium,
           coalesce(f.utm_campaign, '(sem utm)')   AS utm_campaign,
           coalesce(f.page_path, '(desconhecida)') AS entry_page,
           -- Tipo de pagina: a landing tem uma pagina por ticker (centenas de
           -- valores), que como dimensao crua vira so cauda longa. A ordem das
           -- clausulas importa: /ACOES e /AIRTON tambem casariam no regex de ticker.
           CASE
             WHEN f.page_path IS NULL OR f.page_path = '' THEN '(desconhecida)'
             WHEN f.page_path = '/' THEN 'Home'
             WHEN upper(f.page_path) = '/ACOES' THEN 'Lista de acoes'
             WHEN upper(f.page_path) = '/AIRTON' THEN 'Airton'
             WHEN upper(f.page_path) LIKE '/CALCULADORAS%' THEN 'Calculadoras'
             WHEN f.page_path ~ '^/[A-Za-z0-9]{4,7}$' THEN 'Pagina de ticker'
             ELSE 'Outras'
           END AS page_type
    FROM sess s JOIN fp f USING (session_id)
  ),
  -- A landing tem uma pagina por ticker (326 paths distintos no periodo Max).
  -- Sem corte, `dim='pagina'` sozinho responde por metade das linhas do payload.
  -- Top 40 por sessoes no periodo; o resto vira 'Outras paginas'.
  top_pages AS (
    SELECT entry_page FROM sd
    GROUP BY entry_page ORDER BY count(*) DESC, entry_page LIMIT 40
  ),
  -- Unpivot: uma linha por (sessao x dimensao). 9 dimensoes.
  sd_long AS (
    SELECT sd.day, sd.pageviews, sd.cta_clicks, sd.max_scroll, sd.dur_capped,
           sd.is_bounce, d.dim, d.value
    FROM sd
    CROSS JOIN LATERAL (VALUES
      ('fonte',        sd.fonte),
      ('dispositivo',  sd.device_type),
      ('navegador',    sd.browser),
      ('so',           sd.os),
      ('utm_source',   sd.utm_source),
      ('utm_medium',   sd.utm_medium),
      ('utm_campaign', sd.utm_campaign),
      ('pagina',       CASE WHEN sd.entry_page IN (SELECT entry_page FROM top_pages)
                            THEN sd.entry_page ELSE 'Outras paginas' END),
      ('tipo_pagina',  sd.page_type)
    ) AS d(dim, value)
  )
  SELECT jsonb_build_object(
    'iacoes_dim_daily', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT day, dim, value,
               count(*)::int                                  AS sessions,
               sum(pageviews)::int                            AS views,
               sum(cta_clicks)::int                           AS cta_clicks,
               count(*) FILTER (WHERE is_bounce)::int         AS bounces,
               count(*) FILTER (WHERE cta_clicks > 0)::int    AS clicked_sessions,
               count(*) FILTER (WHERE max_scroll >= 25)::int  AS scroll_25,
               count(*) FILTER (WHERE max_scroll >= 50)::int  AS scroll_50,
               count(*) FILTER (WHERE max_scroll >= 75)::int  AS scroll_75,
               count(*) FILTER (WHERE max_scroll >= 100)::int AS scroll_100,
               count(*) FILTER (WHERE pageviews > 1)::int     AS multi_page_sessions,
               sum(dur_capped)::int                           AS dur_sum
        FROM sd_long
        GROUP BY day, dim, value
        ORDER BY day ASC
      ) t
    ),
    -- Scroll real por pagina (nivel pagina, nao first-touch): para cada
    -- (sessao, pagina) pega a profundidade maxima atingida naquela pagina.
    'iacoes_scroll_by_page', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        WITH sp AS (
          SELECT session_id, page_path,
                 max(CASE event_type WHEN 'scroll_100' THEN 100 WHEN 'scroll_75' THEN 75
                                     WHEN 'scroll_50' THEN 50  WHEN 'scroll_25' THEN 25
                                     ELSE 0 END) AS max_scroll,
                 count(*) FILTER (WHERE event_type = 'cta_click') AS cta_clicks
          FROM pv GROUP BY session_id, page_path
        )
        SELECT page_path,
               count(*)::int                                  AS sessions,
               count(*) FILTER (WHERE max_scroll >= 25)::int  AS scroll_25,
               count(*) FILTER (WHERE max_scroll >= 50)::int  AS scroll_50,
               count(*) FILTER (WHERE max_scroll >= 75)::int  AS scroll_75,
               count(*) FILTER (WHERE max_scroll >= 100)::int AS scroll_100,
               sum(cta_clicks)::int                           AS cta_clicks
        FROM sp GROUP BY page_path ORDER BY sessions DESC LIMIT 30
      ) t
    ),
    -- Distribuicao de profundidade da sessao (paginas e duracao REAL, sem cap)
    'iacoes_session_depth', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        SELECT 'paginas' AS kind,
               CASE WHEN pageviews <= 1 THEN '1'
                    WHEN pageviews = 2 THEN '2'
                    WHEN pageviews = 3 THEN '3'
                    WHEN pageviews <= 5 THEN '4-5'
                    WHEN pageviews <= 10 THEN '6-10'
                    ELSE '10+' END AS bucket,
               CASE WHEN pageviews <= 1 THEN 1 WHEN pageviews = 2 THEN 2 WHEN pageviews = 3 THEN 3
                    WHEN pageviews <= 5 THEN 4 WHEN pageviews <= 10 THEN 5 ELSE 6 END AS ord,
               count(*)::int AS sessions
        FROM sd GROUP BY 1, 2, 3
        UNION ALL
        SELECT 'duracao' AS kind,
               CASE WHEN dur_raw < 10 THEN '< 10s'
                    WHEN dur_raw < 30 THEN '10-30s'
                    WHEN dur_raw < 60 THEN '30-60s'
                    WHEN dur_raw < 180 THEN '1-3min'
                    WHEN dur_raw < 600 THEN '3-10min'
                    ELSE '10min+' END AS bucket,
               CASE WHEN dur_raw < 10 THEN 1 WHEN dur_raw < 30 THEN 2 WHEN dur_raw < 60 THEN 3
                    WHEN dur_raw < 180 THEN 4 WHEN dur_raw < 600 THEN 5 ELSE 6 END AS ord,
               count(*)::int AS sessions
        FROM sd GROUP BY 1, 2, 3
        ORDER BY 1, 3
      ) t
    ),
    -- Sankey da landing: Fonte -> Pagina de entrada -> Profundidade -> CTA.
    -- Contrato de linha: {stage, source, target, value}. O stage do `source` e
    -- `stage`; o do `target` e `stage+1`. O frontend deriva os nos.
    'iacoes_landing_sankey', (
      SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
        WITH counted AS (
          SELECT sd.fonte, sd.page_type, sd.max_scroll, sd.cta_clicks,
                 count(*) OVER (PARTITION BY sd.fonte) AS cnt_fonte
          FROM sd
        ),
        ranked AS (
          SELECT c.*,
                 dense_rank() OVER (ORDER BY cnt_fonte DESC, fonte) AS rk_fonte
          FROM counted c
        ),
        node AS (
          SELECT CASE WHEN rk_fonte <= 6 THEN fonte ELSE 'Outras fontes' END AS n_fonte,
                 page_type AS n_page,
                 CASE WHEN max_scroll >= 100 THEN 'Leu ate o fim'
                      WHEN max_scroll >= 75  THEN 'Scroll 75%'
                      WHEN max_scroll >= 50  THEN 'Scroll 50%'
                      WHEN max_scroll >= 25  THEN 'Scroll 25%'
                      ELSE 'Sem scroll' END AS n_depth,
                 CASE WHEN cta_clicks > 0 THEN 'Clicou CTA' ELSE 'Saiu sem clicar' END AS n_cta
          FROM ranked
        )
        SELECT 0 AS stage, n_fonte AS source, n_page  AS target, count(*)::int AS value FROM node GROUP BY 1, 2, 3
        UNION ALL
        SELECT 1 AS stage, n_page  AS source, n_depth AS target, count(*)::int AS value FROM node GROUP BY 1, 2, 3
        UNION ALL
        SELECT 2 AS stage, n_depth AS source, n_cta   AS target, count(*)::int AS value FROM node GROUP BY 1, 2, 3
        ORDER BY 1, 4 DESC
      ) t
    ),
    'meta', jsonb_build_object(
      'from', p_from, 'to', p_to,
      'rpc_version', 'iacoes_v3_20260914',
      'source', 'iacoes_page_views_human (first-touch por sessao)',
      'duration_cap_sec', 1800
    )
  ) INTO result;

  RETURN result;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_analytics_data_iacoes_v3(timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_analytics_data_iacoes_v3(timestamptz, timestamptz) TO service_role;
