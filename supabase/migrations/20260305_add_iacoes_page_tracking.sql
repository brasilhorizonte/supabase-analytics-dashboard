-- Migration: Add iAcoes page view tracking
-- Applied to: BH (dawvgbopyemcayavcatd) via Supabase MCP
-- Date: 2026-03-05
--
-- Creates:
--   - iacoes_page_views table with RLS (anon insert only)
--   - Indexes on created_at, page_path, session_id
--   - 8 new sections in get_analytics_data() RPC:
--     iacoes_overview, iacoes_daily, iacoes_top_pages, iacoes_referrers,
--     iacoes_referrer_daily, iacoes_devices, iacoes_browsers, iacoes_os, iacoes_utm
--
-- Tracking script added to:
--   - iacoes/scripts/template.ts (ticker pages + acoes index)
--   - iacoes/index.html (landing page)
--
-- Dashboard:
--   - New "iAcoes" tab with KPIs, charts, and tables

CREATE TABLE IF NOT EXISTS public.iacoes_page_views (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  session_id text NOT NULL,
  page_path text NOT NULL,
  referrer text,
  utm_source text,
  utm_medium text,
  utm_campaign text,
  device_type text,
  screen_width int,
  browser text,
  os text,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE public.iacoes_page_views ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow anon insert" ON public.iacoes_page_views
  FOR INSERT TO anon WITH CHECK (true);

CREATE INDEX idx_iacoes_pv_created ON public.iacoes_page_views (created_at);
CREATE INDEX idx_iacoes_pv_page ON public.iacoes_page_views (page_path);
CREATE INDEX idx_iacoes_pv_session ON public.iacoes_page_views (session_id);
