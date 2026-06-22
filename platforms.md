# Plataformas Brasil Horizonte

## 1. brasilhorizonte (BH)

**Tipo:** Plataforma SaaS de analise fundamentalista de acoes brasileiras.

**Projeto Supabase:** `dawvgbopyemcayavcatd` (sa-east-1)

**URL:** https://dawvgbopyemcayavcatd.supabase.co

**O que faz:**
- Ferramentas de analise fundamentalista: ValuAI (valuai), Qualitativo AI (qualitativo_ai), Validador (validador), iAlocador (ialocador)
- Relatorios de pesquisa (research_reports) com downloads
- Cotacoes de mercado via BRAPI (brapi_quotes)
- Sistema de assinaturas com planos mensais/anuais/lifetime via Stripe
- Paywall com controle de acesso por plano

**Usuarios:** ~129 profiles, ~106 com eventos rastreados. 14 assinantes ativos, 23 clientes especiais.

**Tabelas principais:**
- `usage_events` — eventos de uso (event_ts, event_name, feature, action, ticker, device_type, referrer, session_id, etc.)
- `profiles` — perfis de usuario (subscription_status, plan, billing_period, is_special_client, uf, municipio)
- `brapi_quotes` — dados de mercado (ticker, price, market_cap, sector, indicadores fundamentalistas)
- `research_reports` — relatorios de pesquisa por empresa
- `report_downloads` — log de downloads de relatorios
- `companies` — empresas cadastradas com ticker
- `iacoes_page_views` — tracking da landing page iAcoes

**Eventos rastreados (via usage_events):**
- `session_start`, `auth_login`, `paywall_block`, `checkout_start`, `payment_succeeded`, `subscription_cancel`
- `qualitativo_run`, `valuai_analysis_start`, `valuai_analysis_complete`, `analysis_run` (validador)
- `portfolio_add_asset`, `portfolio_remove_asset` (ialocador)
- `asset_download`, `feature_open`

**Autenticacao:** Supabase Auth (email/password). Admins verificados via tabela `user_roles`.

---

## 2. Horizon Terminal Access (HTA)

**Tipo:** Terminal de documentos CVM com agente IA para analise fundamentalista.

**Projeto Supabase:** `llqhmywodxzstjlrulcw` (us-west-2)

**URL:** https://llqhmywodxzstjlrulcw.supabase.co

**O que faz:**
- Terminal de pesquisa de documentos CVM (demonstrativos, fatos relevantes, etc.)
- Agente IA que responde perguntas sobre empresas usando documentos como contexto
- Chat com modos de resposta: deep, fast, pro
- Watchlist de tickers
- Proxies para APIs de IA: Gemini, Anthropic, OpenAI, Gemini Market

**Usuarios:** ~30 com eventos rastreados no terminal.

**Tabelas principais:**
- `terminal_events` — eventos do terminal (event_ts, event_name, feature, action, ticker, response_mode, duration_ms, token_count, device_type, browser, os)
- `chat_messages` — mensagens de chat (session_id, role, content, metadata)
- `chat_sessions` — sessoes de chat (user_id, ticker, title)
- `user_login_events` — eventos de login (login_at, user_id, ip_address)
- `user_profiles` — perfis (status, client_type, full_name, email)
- `user_watchlist` — watchlist de tickers
- `documents` — documentos CVM (doc_type, title, summary, document_date, source_url)
- `proxy_daily_usage` — uso diario de proxies IA (proxy_name, model_name, request_count, tokens, error_count)
- `proxy_error_log` — log de erros dos proxies (proxy_name, error_type, status_code)
- `server_token_usage` — tokens consumidos por processos backend (source, model_name, prompt/completion/thoughts_tokens)
- `user_daily_usage` — uso diario historico (question_count, pre-fev/2026)

**Features do terminal (via terminal_events.feature):**
- `agent` — agente IA (actions: task_start, task_end, answer_done, plan_ready, task_error, workflow_error, aborted)
- `chat` — chat (actions: send, mode_change, clear, rate_limit_exceeded)
- `tabs` — abas do terminal (actions: open, close)

**Proxies IA (Edge Functions no HTA):**
- `gemini-proxy` — Google Gemini API (tracking server-side completo)
- `anthropic-proxy` — Anthropic Claude API
- `openai-proxy` — OpenAI API
- `gemini-market-proxy` — Gemini para dados de mercado
- `brapi-proxy` — BRAPI cotacoes (nao-IA)
- `partnr-news-proxy` — Partnr News API (nao-IA)

**Processos backend (server_token_usage.source):**
- `watcher-ai-summary` — resumos automaticos de documentos CVM (maior consumidor: ~112M tokens)
- `tweet-polish` — polimento de tweets
- `telegram-digest` — digests para Telegram
- `podcast-script` — scripts de podcast

**Autenticacao:** Supabase Auth (email/password). Aprovacao manual de usuarios via user_profiles.status.

---

## 3. iAcoes (Landing Page)

**Tipo:** Landing page de acoes brasileiras que serve como funil de aquisicao para o brasilhorizonte.

**URLs:**
- https://iacoes.com.br
- https://iacoes.brasilhorizonte.com.br

**O que faz:**
- Paginas de acoes individuais com dados fundamentalistas (template por ticker)
- Pagina index com lista de acoes
- CTA (call-to-action) que direciona para o brasilhorizonte
- Tracking de page views, sessoes, referrers, UTM, device, browser, OS

**Dados armazenados no BH** (tabela `iacoes_page_views`):
- session_id, page_path, referrer, utm_source/medium/campaign
- device_type, screen_width, browser, os, event_type (pageview/cta_click)

**Metricas de conversao** (calculadas no dashboard):
- Funil: iAcoes views -> CTA clicks -> BH sessions -> BH logins -> BH paywall -> BH payments
- Comparacao de conversao iAcoes vs Google vs Direto vs Outros
- Tickers que mais convertem (extraidos do referrer URL)

**Stack:** HTML estatico gerado por TypeScript templates (iacoes/scripts/template.ts). Hospedado separadamente.

---

## Relacao entre as Plataformas

```
iAcoes (landing page)
  |
  | referrer tracking (iacoes_page_views no BH)
  | CTA clicks -> redirect
  v
brasilhorizonte (SaaS)
  |
  | mesmos usuarios (Supabase Auth)
  | cross-project API calls
  v
Horizon Terminal Access (Terminal IA)
```

- **iAcoes -> BH:** Visitantes chegam via iAcoes, sao rastreados por referrer. CTAs direcionam para signup/login no BH.
- **BH <-> HTA:** Compartilham base de usuarios (Supabase Auth separados mas mesmo ecosystem). O dashboard de analytics agrega dados de ambos.
- **HTA -> APIs IA:** Os proxies no HTA fazem chamadas para Gemini/Anthropic/OpenAI e rastreiam tokens consumidos.
