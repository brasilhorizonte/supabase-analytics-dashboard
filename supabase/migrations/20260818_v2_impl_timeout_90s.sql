-- 2026-08-18/19 — Fix: preset "Máx" (from 2026-01-07) sem dados (erro 57014)
--
-- Diagnostico (2026-08-19): o timeout operante no path REST NAO era o
-- statement_timeout=30s setado como proconfig nas RPCs — `SET statement_timeout`
-- em nivel de funcao nao rearma o timeout da statement ja em execucao, entao
-- esses proconfigs sempre foram inertes via PostgREST. O timeout real vinha da
-- role `authenticator` (statement_timeout=8s), herdado porque `service_role`
-- nao tinha rolconfig proprio. Evidencia nos logs: 57014 disparando ~8-10s apos
-- o inicio da request, inclusive em janela 30d com cache frio.
--
-- get_analytics_data_v2_impl leva ~8s warm / ~17s fria na janela Max (isolada;
-- em producao concorre com as outras 13 RPCs do Promise.all). Todas as demais
-- RPCs janeladas ficam < 0,5s na Max.
--
-- Fix real: statement_timeout=90s na role service_role (unica role usada pela
-- Edge Function no BH desde 2026-05-22). PostgREST aplica rolconfig da role
-- impersonada; requer reload de config.
--
-- Aplicado no BH (dawvgbopyemcayavcatd) via MCP em 2026-08-19.

ALTER ROLE service_role SET statement_timeout = '90s';
NOTIFY pgrst, 'reload config';

-- Mantido por consistencia/documentacao, mas inerte no path REST (ver acima).
ALTER FUNCTION public.get_analytics_data_v2_impl(timestamptz, timestamptz)
  SET statement_timeout = '90s';
