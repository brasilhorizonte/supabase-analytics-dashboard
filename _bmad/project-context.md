---
project_name: 'Supabase Analytics Dashboard'
user_name: 'Gabriel'
date: '2026-04-01'
sections_completed: ['technology_stack', 'db_schema', 'rpc_rules', 'token_tracking', 'edge_functions', 'frontend_patterns', 'cross_project', 'auth', 'critical_rules']
status: 'complete'
rule_count: 45
optimized_for_llm: true
---

# Project Context for AI Agents

_Regras criticas e padroes que agentes IA devem seguir ao implementar codigo neste projeto. Foco em detalhes nao-obvios que agentes errariam sem este contexto._

---

## Technology Stack & Versions

- **Runtime**: Deno (Supabase Edge Functions)
- **Frontend**: HTML/CSS/JS vanilla — SPA inline, sem framework, sem build step
- **Charts**: Chart.js 4.4.1 (CDN)
- **Auth**: Supabase Auth (email/password)
- **DB**: PostgreSQL via Supabase (2 projetos separados)
- **Hosting**: GitHub Pages (frontend) / Supabase Edge Functions (API)

---

## Critical Implementation Rules

### DB Schema — Diferencas Reais vs Migration Files

SEMPRE verificar schema real antes de escrever SQL. Migration files podem estar desatualizadas.

**BH (dawvgbopyemcayavcatd, sa-east-1):**
- `usage_events` usa `event_ts` (NAO `created_at`) como coluna de timestamp

**HTA (llqhmywodxzstjlrulcw, us-west-2):**
- `chat_messages` NAO tem `user_id` — fazer JOIN com `chat_sessions`
- Tabela de login e `user_login_events` (NAO `login_events`), coluna `login_at`
- `proxy_daily_usage`: unique constraint `(user_id, usage_date, proxy_name, model_name)`
- Tabela CVM e `documents` (NAO `cvm_documents`)
- Watchlist e `user_watchlist` (NAO `watchlist`)
- `terminal_events` tem `event_ts` E `created_at`

### RPC Functions

- Padrao: `CREATE OR REPLACE FUNCTION get_analytics_data() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER`
- **OBRIGATORIO**: `GRANT EXECUTE ON FUNCTION get_analytics_data() TO anon, authenticated, service_role`
- Secoes: `jsonb_build_object('key', (SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (...) t))`
- **CREATE OR REPLACE deve incluir TODAS as secoes** — nunca alterar parcialmente (a funcao inteira e substituida)
- `auth.uid()` retorna NULL em SECURITY DEFINER com service role — passar `p_user_id` explicitamente quando necessario
- Snapshot (sem `day`): filtros de data no SQL. Time-series (com `day`): filtros no frontend
- User email JOIN: `LEFT JOIN auth.users u ON u.id = table.user_id` → `coalesce(u.email, user_id::text) as email`
- Secoes compartilhadas (ticker_by_feature, user_inactivity, etc.) devem existir em AMBAS as RPCs
- Migrations BH → aplicar em `dawvgbopyemcayavcatd`. Migrations HTA → aplicar em `llqhmywodxzstjlrulcw`

### Token Tracking

- TOKEN_PRICING e keyed por `model_name` (NAO `proxy_name`)
- Metricas de tokens excluem proxies nao-IA: `WHERE proxy_name NOT IN ('brapi', 'partnr-news')`
- Frontend tambem filtra `model_name != 'unknown'`
- Server-side tracking: `check_proxy_rate_limit` (antes da API call) + `increment_proxy_tokens` (depois)
- Ambas RPCs usam mesma unique key mas atualizam colunas diferentes (sem conflito)
- Fallback: `COALESCE(NULLIF(nova_coluna, 0), coluna_antiga)` para retrocompatibilidade

### Edge Function Deploy

- Proxies usam `functions/<name>/index.ts` com imports relativos para `functions/_shared/cors.ts` e `functions/_shared/supabase.ts`
- `entrypoint_path` deve ser `functions/<name>/index.ts` (NAO `source/index.ts`)
- `analytics-dashboard`: `verify_jwt = false` (gerencia auth internamente para retornar 401 JSON)
- Deploy: `supabase functions deploy <name> --project-ref llqhmywodxzstjlrulcw --no-verify-jwt`
- Novos proxies devem seguir padrao: cors.ts + supabase.ts + classifyError + countRequest + trackTokens

### Frontend — Variaveis Globais

- `dashboardData` — cache do JSON retornado pela API (single source of truth)
- `globalFilters = { gran, from, to, preset }` — filtros ativos (default: 30d)
- `bhSubFilters = { plan, period }` — filtro local BH assinantes
- `charts = {}` — referencias Chart.js para destroy/recreate
- `COLORS = ['#6366f1','#3ecf8e','#f59e0b','#3b82f6','#ec4899','#22c55e',...]`
- `TOKEN_PRICING` — precos por model_name

### Frontend — Helpers Disponiveis (USAR SEMPRE)

- `fmt(n)` — formata numeros | `pct(n)` — formata percentual
- `canvasHTML(id, title)` — HTML padronizado para canvas de chart (OBRIGATORIO para novos charts)
- `buildHTML(tabId, html)` — monta conteudo de tab (OBRIGATORIO para render functions)
- `destroyChart(id)` — destroi chart existente (OBRIGATORIO antes de recriar qualquer chart)
- `makeSortable(tableElement)` — torna tabela ordenavel (OBRIGATORIO para novas tabelas)
- `prepareTimeSeries(data, f, fields)` — serie temporal simples
- `prepareMultiCategoryTS(data, f, catField, valField)` — serie temporal por categoria
- `filterSnapshot(data, f, dateField)` — filtra snapshot por date range
- `richTooltipCallbacks` — tooltip callbacks padrao do Chart.js

### Frontend — Padrao de Render Function

```javascript
function renderXxxYyy() {
    const data = dashboardData.xxx; const f = globalFilters;
    buildHTML('tabId', `...${canvasHTML('chartId','Titulo')}...`);
    // extrair arrays de dados
    // render charts: destroyChart(id) + new Chart(...)
    // render tabelas: innerHTML + makeSortable()
}
// Cada render function chamada em try/catch isolado
```

### Frontend — Chart.js Defaults

- Barras: `borderRadius: 6` | Linhas: `tension: 0.4`
- Grid: `#f1f5f9` | Texto: `#64748b`
- Stacked bars: `scales: { x: { stacked: true }, y: { stacked: true } }`
- Sempre usar `responsive: true, maintainAspectRatio: true`

### Cross-Project Data

- Edge Function (HTA) chama BH via REST API HTTP (nao connection pool)
- BH: usa anon key | HTA: usa service role key
- **Dados BH e HTA NUNCA combinados num mesmo grafico/tabela/KPI**

### Auth & Admins

- Login via `/auth/v1/token?grant_type=password` (projeto HTA)
- Admin check: tabela `user_roles` com `role = 'admin'` usando service role key
- Admins: lucasmello@brasilhorizonte.com.br, lucastnm@gmail.com, gabriel.dantas@brasilhorizonte.com.br

### Critical Dont-Miss Rules

- Supabase Edge Functions NAO servem HTML (reescrevem `text/html` para `text/plain`)
- `proxy_error_log` so recebe dados quando proxies IA encontram erros upstream
- Error classification: rate_limit(429), upstream_unavailable(503), timeout(408), client_error(4xx), upstream_error(5xx), unknown
- iAcoes tracking usa BH anon key, tabela `iacoes_page_views`, RLS com anon insert only
- Uma RPC, um JSON — `get_analytics_data()` retorna tudo, frontend filtra/agrega
- Zero build step — tudo inline num unico `index.html`

---

## Usage Guidelines

**Para Agentes IA:**
- Ler este arquivo ANTES de implementar qualquer codigo
- Seguir TODAS as regras exatamente como documentadas
- Em caso de duvida, preferir a opcao mais restritiva
- Atualizar este arquivo se novos padroes emergirem

**Para Humanos:**
- Manter este arquivo enxuto e focado em necessidades de agentes
- Atualizar quando stack tecnologica mudar
- Revisar trimestralmente para remover regras obsoletas

Last Updated: 2026-04-01
