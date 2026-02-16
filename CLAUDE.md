# Supabase Analytics Dashboard

Dashboard de analytics em tempo real para os projetos **brasilhorizonte** e **Horizon Terminal Access** da Brasil Horizonte.

## Arquitetura

O projeto tem duas camadas separadas:

1. **Frontend** (`index.html`): Single-page app com login, graficos Chart.js e 4 abas de metricas. Hospedado como arquivo estatico (GitHub Pages ou Supabase Storage). Nao usa framework — tudo inline (CSS + JS).

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
supabase/
  config.toml                # Config do projeto (project_id, verify_jwt)
  functions/
    analytics-dashboard/
      index.ts               # Edge Function - API JSON com auth admin
  migrations/
    20260212_..._brasilhorizonte.sql    # RPC get_analytics_data() no BH
    20260212_..._horizon_terminal.sql   # RPC get_analytics_data() no HTA
    20260216_enhance_token_analytics.sql # Token stats, mode breakdown, top queries + COALESCE tokens reais
```

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
- `token_usage_daily`: tokens por dia/proxy (prefere tokens reais via COALESCE)
- `token_usage_summary`: totais por proxy
- `token_usage_by_user`: consumo por usuario/proxy
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
- **Token tracking**: Colunas `total_prompt_tokens`, `total_completion_tokens`, `total_tokens` em `proxy_daily_usage` e `token_count`, `response_mode` em `terminal_events` foram adicionadas mas podem estar zeradas ate o tracking no app popular os dados. A RPC usa `COALESCE(NULLIF(nova_coluna, 0), coluna_antiga)` para fallback transparente.

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

## Token Pricing (frontend)

```javascript
const TOKEN_PRICING = {
    'anthropic': { input: 3.00, output: 15.00, label: 'Claude Sonnet 4' },
    'gemini': { input: 1.25, output: 10.00, label: 'Gemini 2.5 Pro' },
    'gemini-market': { input: 0.30, output: 2.50, label: 'Gemini 2.5 Flash' },
};
```

Custo calculado por `(input_tokens / 1M) * input_price + (output_tokens / 1M) * output_price`. Os `proxy_name` usados sao `anthropic`, `gemini` e `gemini-market`.

## Stack

- **Runtime**: Deno (Supabase Edge Functions)
- **Frontend**: HTML/CSS/JS vanilla + Chart.js 4.4.1
- **Auth**: Supabase Auth (email/password)
- **DB**: PostgreSQL (via Supabase)
- **Hosting**: GitHub Pages ou Supabase Storage
