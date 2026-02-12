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
- `terminal_daily`: ultimos 14 dias (sessions, tasks, chat_msgs)
- `terminal_events_summary`: eventos por feature/action com avg_duration_ms
- `chat_daily`: mensagens e usuarios unicos por dia
- `documents_by_type`: documentos CVM agrupados por tipo
- `watchlist`: tickers na watchlist dos usuarios
- `user_profiles_summary`: perfis por status e client_type
- `login_daily`: logins e usuarios unicos por dia

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

## Stack

- **Runtime**: Deno (Supabase Edge Functions)
- **Frontend**: HTML/CSS/JS vanilla + Chart.js 4.4.1
- **Auth**: Supabase Auth (email/password)
- **DB**: PostgreSQL (via Supabase)
- **Hosting**: GitHub Pages ou Supabase Storage
