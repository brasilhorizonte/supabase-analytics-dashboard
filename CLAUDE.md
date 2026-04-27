# iAcoes Analytics Dashboard

Dashboard de analytics em tempo real para os projetos **brasilhorizonte** (UI: "iAcoes") e **Horizon Terminal Access** da Brasil Horizonte.

> **Nota de branding (2026-04-25):** O dashboard foi renomeado de "Brasil Horizonte / BH" para "iAcoes" apenas em UI/labels (sidebar, titulo, tabs). Variaveis JS internas (`bhData`, `bhSubFilters`, `renderBh*`), IDs de elementos (`bhVisao`, `bhEngajamento`...) e chaves do response da Edge Function (`bh: {...}`) **continuam usando o prefixo `bh`** para preservar compatibilidade.

## Arquitetura

O projeto tem duas camadas separadas:

1. **Frontend** (`index.html`): Single-page app com login, sidebar lateral dark com grupos colapsaveis por plataforma (iAcoes: 6 sub-abas, Horizon Terminal: 6 sub-abas, Landing iAcoes standalone), area de conteudo light, filtros globais. Hospedado como arquivo estatico (GitHub Pages ou Supabase Storage). Nao usa framework — tudo inline (CSS + JS).

2. **API** (`supabase/functions/analytics-dashboard/index.ts`): Edge Function no Supabase que retorna JSON. Verifica JWT do usuario via Supabase Auth e checa role `admin` na tabela `user_roles`. Busca dados de ambos os projetos via RPC functions (`get_analytics_data`, `get_analytics_data_bh_extras`, `get_notification_analytics`, `get_geo_profiles`).

## Projetos Supabase

| Projeto | ID | Regiao | Descricao |
|---------|-----|--------|-----------|
| brasilhorizonte | `dawvgbopyemcayavcatd` | sa-east-1 | Plataforma SaaS de analise fundamentalista |
| Horizon Terminal Access | `llqhmywodxzstjlrulcw` | us-west-2 | Terminal de documentos CVM + agente IA |

A Edge Function roda no projeto **Horizon Terminal Access** e faz chamadas cross-project para o **brasilhorizonte** via REST API.

## Autenticacao

- `verify_jwt = false` na Edge Function (ela gerencia auth internamente para poder retornar 401 JSON ao inves do 403 padrao do Supabase)
- Login via `/auth/v1/token?grant_type=password` do Supabase Auth (projeto HTA)
- Verificacao de admin: consulta tabela `user_roles` com `role = 'admin'` usando service role key
- Admins: lucasmello@brasilhorizonte.com.br, lucastnm@gmail.com, gabriel.dantas@brasilhorizonte.com.br

## Estrutura de Arquivos

```
index.html                   # Frontend SPA (login + dashboard + Chart.js)
deploy.sh                    # Script de deploy para Supabase Storage
CLAUDE.md                    # Documentacao do projeto
supabase/
  config.toml                # Config do projeto (project_id, verify_jwt)
  functions/
    analytics-dashboard/
      index.ts               # Edge Function - API JSON com auth admin
  migrations/
    20260212_..._brasilhorizonte.sql        # RPC get_analytics_data() no BH
    20260212_..._horizon_terminal.sql       # RPC get_analytics_data() no HTA
    20260216_enhance_token_analytics.sql    # Token stats, mode breakdown, top queries + COALESCE tokens reais
    20260226_add_error_metrics.sql          # proxy_error_log table, error_count column, log_proxy_error RPC
    20260301_filter_non_ai_proxies.sql      # Filtra brapi/partnr-news das metricas de tokens na RPC
    20260418_bh_revenue_and_new_metrics.sql # Revenue fixes, trial funnel, portfolio/CVM/alert/email/whatsapp
    20260420_email_log_welcome_idempotency.sql
    20260422_filter_iacoes_bots.sql         # Filtra crawlers/bots de iacoes_page_views
    20260425_iacoes_macro_beta_paywall_v2.sql # Macro Beta + Paywall v2 + CVM v2 + lifetime feature usage
    20260427_bh_usage_events_utm.sql        # NEW RPC get_analytics_data_bh_utm() — UTM attribution + 50OFF campaign
```

## UTM Attribution (2026-04-27)

Captura e visualizacao de campanhas via parametros `utm_*` em `usage_events` (tabela do projeto BH).

- **Nova RPC** `get_analytics_data_bh_utm()` (additive — nao toca em `get_analytics_data` ou `get_analytics_data_bh_extras`). Retorna 7 secoes:
  - `usage_utm_summary` — top 30 source/medium/campaign nos ultimos 90d
  - `usage_utm_daily` — serie diaria por utm_source
  - `usage_utm_by_content` — top 50 criativos (utm_content) com sessions/logins/payments
  - `usage_utm_funnel_by_source` — conversao por fonte (sessao -> login -> paywall -> pagamento), session-level join
  - `usage_utm_50off_summary` — snapshot da campanha 50OFF (window 27/04 a 03/05 BRT)
  - `usage_utm_50off_daily` — serie diaria da campanha
  - `usage_utm_50off_top_content` — top 30 criativos da campanha
- **Edge function**: `analytics-dashboard/index.ts` adicionou um 7º `fetchRpc(BH_URL, BH_ANON, "get_analytics_data_bh_utm")` no `Promise.all` e merge no `bhMerged` via spread.
- **Frontend** (`index.html`): tab `bhAquisicao` ganhou 2 secoes — "Campanhas UTM" (KPIs + bar chart top sources + stacked daily + funnel-by-source table + top criativos table) e "Campanha 50OFF" (KPIs hero com CVR/checkout rate + daily stacked por fonte + top criativos da campanha).
- **Campaign window** harcoded na RPC: `promo_start = '2026-04-27 00:00:00-03'` / `promo_end = '2026-05-03 23:59:59-03'`. Pra campanhas futuras, criar nova RPC ou parametrizar.
- **Convencao do `utm_content`**: `{feature}_{canal}_{formato}` — ex: `valuai_yt_video`, `score_ig_reel`, `radar_tw_thread`. Permite pivoting limpo.

## Edge Functions (Proxy)

Alem da `analytics-dashboard`, existem 6 Edge Functions de proxy deployadas no projeto HTA. Elas **nao** fazem parte deste repositorio — sao gerenciadas diretamente via Supabase (MCP ou CLI).

| Function | verify_jwt | Descricao |
|----------|-----------|-----------|
| `analytics-dashboard` | false | API do dashboard (neste repo) |
| `gemini-proxy` | false | Proxy para Google Gemini API (tracking server-side: requests + tokens) |
| `anthropic-proxy` | false | Proxy para Anthropic Claude API |
| `gemini-market-proxy` | false | Proxy para Gemini + BRAPI (mercado financeiro) |
| `openai-proxy` | true | Proxy para OpenAI API |
| `brapi-proxy` | false | Proxy para brapi.dev (cotacoes) |
| `partnr-news-proxy` | false | Proxy para Partnr News API |

### Deploy de proxies (file structure)

Os proxies usam imports relativos para `../_shared/cors.ts` e `../_shared/supabase.ts`. Ao deployar via MCP, a estrutura de arquivos deve ser:

```
functions/<proxy-name>/index.ts   # entrypoint
functions/_shared/cors.ts         # CORS helpers
functions/_shared/supabase.ts     # Supabase client helpers
```

Com `entrypoint_path: "functions/<proxy-name>/index.ts"`.

## API Response

A Edge Function retorna:

```json
{
  "admin": "email@example.com",
  "bh": { "overview": {...}, "daily_activity": [...], "feature_usage": [...], ... },
  "hta": { "overview": {...}, "terminal_daily": [...], "chat_daily": [...], ... },
  "ts": "2026-02-12T..."
}
```

### Dados BH / iAcoes (brasilhorizonte)

Edge Function faz merge de 3 RPCs no BH: `get_analytics_data` (base), `get_notification_analytics` (notificacoes/Telegram) e `get_analytics_data_bh_extras` (revenue + features novas). O resultado vai para `bh.*` no response.

**Base (`get_analytics_data`):**
- `overview`: db_size_bytes, total_users, active_sessions, storage_objects
- `daily_activity`: ultimos 30 dias (day, events, dau)
- `usage_events_summary`: eventos agrupados por nome
- `feature_usage`: features mais usadas
- `conversion_funnel`: users unicos (DISTINCT) por step: sessions → logins → paywall → checkout → payments → cancels
- `retention_cohorts`: cohorts mensais com retencao em janelas de 7d (window 7-14d, 30-37d, 60-67d, 90-97d)
- `ticker_by_feature`: tickers agrupados por ferramenta (qualitativo_ai, valuai, validador, etc.)
- `ticker_trend_daily`: top 10 tickers ao longo do tempo
- `feature_usage_trend`: adocao de ferramentas ao longo do tempo (eventos com ticker)
- `user_inactivity` / `inactivity_distribution` / `user_feature_breadth`
- `ticker_ranking` / `user_ticker_usage` / `user_ticker_detail`
- `top_tickers_market`, `sector_distribution`, `report_downloads_daily`
- `iacoes_*` (overview, daily, top_pages, referrers, devices, browsers, os, utm, conversion_funnel, cta_breakdown, ...) — landing page tracking

**Notification (`get_notification_analytics`):**
- `notifications_by_type_daily`, `notifications_delivery`, `notifications_delivery_daily`, `notifications_top_tickers`
- `telegram_overview`, `telegram_links_daily`
- `notification_funnel`, `notification_prefs_summary`, `notification_type_popularity`

**Extras (`get_analytics_data_bh_extras` — revenue + features novas):**
- `active_subscribers_daily`, `new_subscribers_daily`, `trial_funnel_daily`, `subscription_trials_daily`
- `revenue_by_plan_fixed`: MRR estimado com pricing autoritativo (essencial 29.90, fundamentalista 49.90, ianalista 39.90, ialocador 59.90, valor 149.90)
- `portfolio_activity_daily`: adds, removes, saves, loads, **deletes**, **ianalises**, content_filters, cvm_filters, **photo_imports**, unique_users
- `portfolio_top_tickers`: top 15 tickers adicionados a portfolios
- `cvm_activity_daily`: expansions, filters, **pdf_clicks**, **telegram_clicks**, **telegram_dismisses**, **type_toggles**
- `cvm_interactions_summary`: KPIs agregados de todos os eventos `cvm_*`
- `tab_usage`: top 30 (feature, tab) por views
- `alert_rules_summary` / `alert_rules_daily` / `alert_rules_top_tickers`
- `activation_funnel` / `activation_summary` (de `investor_profiles`)
- `email_log_summary` / `email_log_daily` / `whatsapp_log_summary` / `whatsapp_log_daily`
- **`macro_beta_overview`**: views, runs_success/error, verdicts, drill_downs, tooltips, sort_changes, upgrade_clicks, coupon_copies, saved_total/users (Macro Beta lancado em 2026-04-23)
- **`macro_beta_daily`**: time series por evento `macro_*`
- **`macro_beta_funnel`**: viewed → ran → drilled → saved → upgrade_clicked (usuarios unicos)
- **`paywall_v2_summary`**: credit_exhausted, teaser_views/cta_clicks, hint_shown, export_paywall, passive_clicks, portfolio_detected, ticker_searches, unique_users_blocked
- **`paywall_v2_daily`**: stacked time series dos 5 tipos de paywall
- **`paywall_v2_funnel`**: bloqueados → teaser_views → cta_clicks → checkout
- **`empty_portfolio_funnel`**: banner_views → cta_clicks → imports_confirmed → photo_imports OK/error
- **`companion_messages_daily`**: mensagens enviadas ao IAnalista chat (`companion_message_sent`)
- **`valuai_save_share_summary`**: analyses_started/completed, saves, shares, shared_loads, unique_savers/sharers
- **`lifetime_feature_usage_summary`**: usos por feature gated (valuai, qualitativo, validador, macro) com unique_users
- **`lifetime_feature_top_users`**: top 20 usuarios por uso lifetime (com email, features_used, last_used_at)

### Dados HTA (Horizon Terminal)
- `overview`: db_size_bytes, total_users, active_sessions, storage_objects
- `last_24h`: sessions, tasks, chat_msgs, logins, unique_users, requests, tokens
- `terminal_daily`: ultimos 14 dias (sessions, tasks, chat_msgs)
- `terminal_events_summary`: eventos por feature/action com avg_duration_ms
- `chat_daily`: mensagens e usuarios unicos por dia
- `daily_usage`: requests diarios do proxy
- `documents_by_type`: documentos CVM agrupados por tipo
- `watchlist`: tickers na watchlist dos usuarios
- `user_profiles_summary`: perfis por status e client_type
- `login_daily`: logins e usuarios unicos por dia
- `top_tickers_searched`: tickers mais buscados no terminal
- `table_sizes`: tamanhos e rows das tabelas publicas
- `token_usage_daily`: tokens por dia/modelo IA (exclui brapi/partnr-news, agrupa por model_name)
- `token_usage_summary`: totais por modelo IA
- `token_usage_by_user`: consumo por usuario/modelo IA
- `token_stats`: metricas agregadas de queries IA (total, com token_count, media)
- `token_by_mode`: breakdown por response_mode (deep/fast/pro)
- `top_queries_by_token`: top 20 queries mais caras em tokens
- `device_summary` / `device_daily`: metricas por tipo de dispositivo
- `os_summary` / `browser_summary`: distribuicao de SO e navegador
- `agent_success_daily`: taxa de sucesso do agente IA por dia
- `agent_duration_daily`: duracao media/mediana/max do agente por dia
- `response_mode_summary` / `response_mode_daily`: uso de modos de resposta
- `chat_depth_distribution`: profundidade das sessoes de chat (buckets)
- `questions_daily`: perguntas diarias de user_daily_usage
- `questions_by_user`: total de perguntas por usuario (email, total_questions) de user_daily_usage
- `proxy_error_daily`: erros por dia/proxy/tipo (da tabela `proxy_error_log`)
- `proxy_error_summary`: resumo de erros por proxy/tipo/status_code com first_seen e last_seen
- `proxy_error_rate_daily`: taxa de erro diaria por proxy (erro / (requests + erros) * 100)
- `ticker_by_feature`: tickers agrupados por feature (agent, chat, tabs)
- `ticker_trend_daily`: top 10 tickers ao longo do tempo
- `feature_usage_trend`: adocao de features ao longo do tempo (eventos com ticker)
- `user_inactivity`: lista de users com last_event_ts, days_inactive, email, total_events
- `inactivity_distribution`: buckets de inatividade (ativo hoje, 1-3d, 4-7d, 8-14d, 15-30d, 30d+)
- `user_feature_breadth`: distribuicao de users por numero de features usadas (1, 2, 3, 4+)
- `ticker_ranking`: ranking consolidado dos top 20 tickers por uso total (ticker, cnt)
- `user_ticker_usage`: uso por usuario com tickers (email, total_queries, unique_tickers, top_ticker, top_feature, last_activity) LIMIT 100
- `user_ticker_detail`: breakdown detalhado por usuario/ticker/feature (user_id, ticker, feature, cnt)

## Deploy

### Edge Function
```bash
supabase functions deploy analytics-dashboard --project-ref llqhmywodxzstjlrulcw --no-verify-jwt
```

### Frontend (GitHub Pages)
Push para `main` com GitHub Pages ativado em Settings > Pages > Source: main / root.

### Frontend (Supabase Storage)
```bash
./deploy.sh   # pede a Service Role Key do projeto HTA
```

Ou upload manual: Dashboard Supabase > Storage > bucket `dashboard` > upload index.html
URL: `https://llqhmywodxzstjlrulcw.supabase.co/storage/v1/object/public/dashboard/index.html`

## Limitacoes Conhecidas

- **Supabase Edge Functions nao servem HTML**: GET requests com `Content-Type: text/html` sao reescritos para `text/plain`. Por isso o frontend e hospedado separadamente.
- **Supabase Storage pode nao renderizar HTML**: Dependendo da configuracao, o Storage pode forcar download ao inves de renderizar. GitHub Pages e mais confiavel para hospedar o frontend.
- **Cross-project data**: A Edge Function usa anon key do BH e service role key do HTA. Se as keys mudarem, atualizar no codigo.
- **RPC functions**: Criadas com `SECURITY DEFINER` e precisam de `GRANT EXECUTE` para anon/authenticated/service_role.
- **Token tracking server-side**: O `gemini-proxy` (v256+) faz tracking completo server-side: `check_proxy_rate_limit` (request counting + rate limit 500/dia) e `increment_proxy_tokens` (tokens com model_name correto). As metricas de tokens excluem proxies nao-IA (brapi, partnr-news) tanto na RPC (`WHERE proxy_name NOT IN (...)`) quanto no frontend (`isAiToken` filter). A RPC usa `COALESCE(NULLIF(nova_coluna, 0), coluna_antiga)` para fallback transparente.
- **Error metrics**: A tabela `proxy_error_log` so recebe dados quando os proxies IA (gemini, anthropic, gemini-market) encontram erros upstream. A secao "Erros de API" no dashboard mostra "Nenhum erro registrado" ate que erros reais ocorram.

## Comandos Uteis

```bash
# Deploy da Edge Function
supabase functions deploy analytics-dashboard --project-ref llqhmywodxzstjlrulcw --no-verify-jwt

# Ver logs da Edge Function
supabase functions logs analytics-dashboard --project-ref llqhmywodxzstjlrulcw

# Testar API localmente (substitua TOKEN pelo access_token do Supabase Auth)
curl -H "Authorization: Bearer TOKEN" https://llqhmywodxzstjlrulcw.supabase.co/functions/v1/analytics-dashboard

# Aplicar migrations
supabase db push --project-ref dawvgbopyemcayavcatd   # BH
supabase db push --project-ref llqhmywodxzstjlrulcw   # HTA
```

## Token Pricing (frontend, keyed por model_name)

```javascript
const TOKEN_PRICING = {
    'claude-sonnet-4-20250514': { input: 3.00, output: 15.00, label: 'Claude Sonnet 4' },
    'claude-opus-4-20250514':   { input: 15.00, output: 75.00, label: 'Claude Opus 4' },
    'gemini-3.1-pro-preview':   { input: 2.00, output: 12.00, label: 'Gemini 3.1 Pro' },
    'gemini-2.5-pro':           { input: 1.25, output: 10.00, label: 'Gemini 2.5 Pro' },
    'gemini-2.5-flash':         { input: 0.30, output: 2.50, label: 'Gemini 2.5 Flash' },
    'gemini-2.0-flash-lite':    { input: 0.10, output: 0.40, label: 'Gemini 2.0 Flash Lite' },
};
```

Custo calculado por `(input_tokens / 1M) * input_price + (output_tokens / 1M) * output_price`. A tabela `proxy_daily_usage` agora tem `model_name` alem de `proxy_name`. Tokens sao persistidos server-side pelas Edge Functions.

### proxy_name e model_name

| proxy_name | model_name | IA? | Descricao |
|------------|-----------|-----|-----------|
| `anthropic` | `claude-sonnet-4-20250514`, `claude-opus-4-20250514` | Sim | Modelo real da API |
| `gemini` | `gemini-2.5-pro`, `gemini-2.5-flash`, etc. | Sim | Modelo real da API |
| `gemini-market` | `gemini-2.5-flash`, etc. | Sim | Modelo real da API |
| `openai` | `gpt-5.1`, etc. | Sim | Modelo real da API |
| `brapi` | `brapi` | **Nao** | Excluido das metricas de tokens |
| `partnr-news` | `partnr-news` | **Nao** | Excluido das metricas de tokens |

### Server-side tracking (gemini-proxy v256+)

O `gemini-proxy` faz tracking completo server-side em 2 etapas:

1. **Antes da API call**: `check_proxy_rate_limit(p_proxy_name, p_model_name, p_daily_limit)` — conta request + aplica rate limit (500/dia). ON CONFLICT so atualiza `request_count`.
2. **Apos a API call**: `increment_proxy_tokens(p_proxy_name, p_prompt_tokens, p_completion_tokens, p_total_tokens, p_model_name)` — persiste tokens. ON CONFLICT so atualiza colunas de tokens.

As duas RPCs usam a mesma unique key `(user_id, usage_date, proxy_name, model_name)` mas atualizam colunas diferentes, entao nao conflitam. O tracking funciona nos 3 caminhos: multimodal, streaming SSE, e texto simples.

## Error Metrics

Sistema de metricas de erro para proxies IA (gemini, anthropic, gemini-market).

### Tabelas

- **`proxy_error_log`**: Log detalhado de erros (user_id, proxy_name, model_name, error_type, status_code, error_message, created_at). RLS ativado mas sem policies (acessada via SECURITY DEFINER).
- **`proxy_daily_usage.error_count`**: Coluna adicional que conta erros por dia/proxy/modelo.

### RPC `log_proxy_error()`

Chamada pelas Edge Functions quando um erro upstream ocorre. Recebe `p_user_id` explicitamente (nao usa `auth.uid()`). Insere em `proxy_error_log` e incrementa `error_count` em `proxy_daily_usage`.

### Classificacao de erros

Os proxies classificam erros via `classifyError()`:
- `rate_limit` (429)
- `upstream_unavailable` (503 ou mensagem overloaded/unavailable)
- `timeout` (408 ou mensagem timeout)
- `client_error` (4xx)
- `upstream_error` (5xx)
- `unknown` (outros)

### Dashboard

Secao "Erros de API" na aba HTA com:
- KPIs: Total Erros, Taxa de Erro, Proxy + Afetado, Erros Hoje
- Grafico de barras empilhadas: erros por dia por proxy
- Grafico de linhas: taxa de erro (%) por dia por proxy
- Tabela: erros por tipo com proxy, tipo, status code, contagem, first/last seen

## Frontend Layout

O dashboard usa layout com sidebar lateral + area de conteudo light (estilo Kondado).

### Estrutura visual
- **Login page**: tema dark standalone (variaveis CSS scopadas no `.login-container`)
- **Sidebar** (240px, fixed): dark (#1a1d2e), logo "iAcoes" + grupos colapsaveis por plataforma
  - **iAcoes** (6 sub-abas): Visao Geral, Aquisicao, Engajamento, Retencao, Receita & Assinaturas, Detalhes
  - **Horizon Terminal** (6 sub-abas): Visao Geral, Aquisicao, Engajamento, Retencao, Custos, Detalhes
  - **Landing iAcoes** (standalone — tracking do site `iacoes.brasilhorizonte.com.br`)
- **Top bar** (sticky): titulo da aba (`iAcoes - X` / `HTA - X`) + filtros globais + admin info
- **Area de conteudo**: fundo claro (#f5f7fa), cards brancos com sombra sutil
- **Regra**: dados iAcoes (BH) e HTA nunca combinados num mesmo grafico/tabela/KPI

> **Internamente** as variaveis JS continuam com prefixo `bh` (`bhVisao`, `bhEngajamento`, `bhCustos`, `dashboardData.bh`, `bhSubFilters`, `renderBhEngajamento`...) — a renomeacao foi apenas em strings visiveis ao admin.

### Filtros globais
- **Presets**: 7d, 30d (default), 90d, Custom
- **Date picker**: inputs de data (from/to) visiveis quando Custom selecionado
- **Granularidade**: Diario, Semanal, Mensal
- Estado mantido em `globalFilters = { gran, from, to, preset }`
- Filtros locais: apenas `bhSubFilters = { plan, period }` para secao de assinantes BH

### Responsivo (mobile)
- Sidebar collapsa (translateX) com botao hamburger na top bar
- Overlay escuro ao abrir sidebar
- Top bar reorganiza filtros em nova linha

### Chart.js defaults
- Barras arredondadas (`borderRadius: 6`), linhas suaves (`tension: 0.4`)
- Grid sutil (`#f1f5f9`), texto (`#64748b`)
- Cores: `['#6366f1','#3ecf8e','#f59e0b','#3b82f6','#ec4899','#22c55e',...]`

## Stack

- **Runtime**: Deno (Supabase Edge Functions)
- **Frontend**: HTML/CSS/JS vanilla + Chart.js 4.4.1
- **Auth**: Supabase Auth (email/password)
- **DB**: PostgreSQL (via Supabase)
- **Hosting**: GitHub Pages ou Supabase Storage
