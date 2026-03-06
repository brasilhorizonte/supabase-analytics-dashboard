# Supabase Analytics Dashboard

Dashboard de analytics em tempo real para os projetos **brasilhorizonte** e **Horizon Terminal Access** da Brasil Horizonte.

## Arquitetura

O projeto tem duas camadas separadas:

1. **Frontend** (`index.html`): Single-page app com login, graficos Chart.js e 5 abas de metricas. Hospedado como arquivo estatico (GitHub Pages ou Supabase Storage). Nao usa framework — tudo inline (CSS + JS).

2. **API** (`supabase/functions/analytics-dashboard/index.ts`): Edge Function no Supabase que retorna JSON. Verifica JWT do usuario via Supabase Auth e checa role `admin` na tabela `user_roles`. Busca dados de ambos os projetos via RPC functions.

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
```

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

### Dados BH (brasilhorizonte)
- `overview`: db_size_bytes, total_users, active_sessions, storage_objects
- `daily_activity`: ultimos 30 dias (day, events, dau)
- `usage_events_summary`: eventos agrupados por nome
- `feature_usage`: features mais usadas
- `conversion_funnel`: sessions → logins → paywall → checkout → payments → cancels
- `top_tickers_market`: tickers por market cap com preco, setor, DY, P/L
- `sector_distribution`: tickers agrupados por setor
- `report_downloads_daily`: downloads de relatorios por dia

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
- `proxy_error_daily`: erros por dia/proxy/tipo (da tabela `proxy_error_log`)
- `proxy_error_summary`: resumo de erros por proxy/tipo/status_code com first_seen e last_seen
- `proxy_error_rate_daily`: taxa de erro diaria por proxy (erro / (requests + erros) * 100)

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

## Stack

- **Runtime**: Deno (Supabase Edge Functions)
- **Frontend**: HTML/CSS/JS vanilla + Chart.js 4.4.1
- **Auth**: Supabase Auth (email/password)
- **DB**: PostgreSQL (via Supabase)
- **Hosting**: GitHub Pages ou Supabase Storage
