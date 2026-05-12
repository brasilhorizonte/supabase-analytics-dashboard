-- Aumenta statement_timeout das RPCs de analytics para 30s.
--
-- Problema: anon role do BH tem statement_timeout=3s (vs 8s no authenticated).
-- A edge function `analytics-dashboard` chama 10 RPCs em paralelo via
-- BH_ANON. Com janela de 90d, `get_analytics_data_v2` sozinha leva ~2.7s;
-- em paralelo disputando recursos, estoura os 3s e o Postgres cancela
-- ("canceling statement due to statement timeout"). fetchRpc na edge function
-- retorna null silenciosamente -> dashboard parece "nao carregar" em 90d.
--
-- Fix cirurgico: ALTER FUNCTION ... SET statement_timeout aplica APENAS
-- dentro da execucao dessas funcoes. Nao afeta o resto do anon role.
-- 30s deixa margem confortavel (RPCs individuais ficam <3s, mesmo em
-- paralelo dificilmente passariam de 10s).

ALTER FUNCTION public.get_analytics_data_v2(timestamptz, timestamptz) SET statement_timeout = '30s';
ALTER FUNCTION public.get_analytics_data_bh_extras_v2(timestamptz, timestamptz) SET statement_timeout = '30s';
ALTER FUNCTION public.get_analytics_data_bh_utm_v2(timestamptz, timestamptz) SET statement_timeout = '30s';
ALTER FUNCTION public.get_analytics_data_iacoes_daily_v2(timestamptz, timestamptz) SET statement_timeout = '30s';
ALTER FUNCTION public.get_analytics_data_bh_oauth_v2(timestamptz, timestamptz) SET statement_timeout = '30s';
ALTER FUNCTION public.get_analytics_data_airton_v2(timestamptz, timestamptz) SET statement_timeout = '30s';
ALTER FUNCTION public.get_notification_analytics() SET statement_timeout = '30s';
