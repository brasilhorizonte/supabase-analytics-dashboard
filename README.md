# Supabase Analytics Dashboard

Dashboard em tempo real para monitoramento dos projetos **brasilhorizonte** e **Horizon Terminal Access**.

## Arquitetura

- **Frontend** (`index.html`): Dashboard completo com login, graficos e metricas. Hospedado no Supabase Storage (bucket publico)
- **API** (`analytics-dashboard` Edge Function): Retorna JSON com dados de ambos os projetos. Verifica JWT e role admin
- **RPC Functions** (`get_analytics_data`): Agregam dados analiticos em cada projeto
- **Autenticacao**: Login via Supabase Auth + verificacao de role `admin` na tabela `user_roles`

## Deploy Rapido

### 1. Clone o repositorio

```bash
git clone <repo-url>
cd supabase-analytics-dashboard
```

### 2. Execute o script de deploy

```bash
chmod +x deploy.sh
./deploy.sh
```

O script vai pedir a **Service Role Key** do projeto Horizon Terminal Access.
Encontre em: https://supabase.com/dashboard/project/llqhmywodxzstjlrulcw/settings/api

### 3. Acesse o dashboard

```
https://llqhmywodxzstjlrulcw.supabase.co/storage/v1/object/public/dashboard/index.html
```

Faca login com seu email/senha de admin.

## Deploy Alternativo (Manual)

Se preferir, voce pode fazer upload manualmente:

1. Acesse https://supabase.com/dashboard/project/llqhmywodxzstjlrulcw/storage/buckets/dashboard
2. Clique em "Upload file"
3. Selecione o arquivo `index.html`
4. Acesse: `https://llqhmywodxzstjlrulcw.supabase.co/storage/v1/object/public/dashboard/index.html`

## Deploy via GitHub Pages

Se o repositorio estiver no GitHub:

1. Va em Settings > Pages
2. Em Source, selecione a branch `main` e pasta `/ (root)`
3. Salve e aguarde o deploy
4. Acesse via `https://SEU-USUARIO.github.io/NOME-DO-REPO/`

## Acesso

Apenas usuarios com role `admin` na tabela `user_roles` do projeto Horizon Terminal Access podem acessar.

### Admins atuais
- lucasmello@brasilhorizonte.com.br
- lucastnm@gmail.com
- gabriel.dantas@brasilhorizonte.com.br

## URLs

| Recurso | URL |
|---------|-----|
| Dashboard | `https://llqhmywodxzstjlrulcw.supabase.co/storage/v1/object/public/dashboard/index.html` |
| API | `https://llqhmywodxzstjlrulcw.supabase.co/functions/v1/analytics-dashboard` |

## Estrutura

```
supabase-analytics-dashboard/
+-- index.html              <- Frontend (single-page app)
+-- deploy.sh               <- Script de deploy automatico
+-- README.md
+-- .env.example
+-- .gitignore
+-- supabase/
    +-- config.toml
    +-- functions/
    |   +-- analytics-dashboard/
    |       +-- index.ts     <- API JSON (Edge Function)
    +-- migrations/
        +-- 20260212_create_analytics_rpc_brasilhorizonte.sql
        +-- 20260212_create_analytics_rpc_horizon_terminal.sql
```

## Metricas

### brasilhorizonte
- Usuarios, sessoes, storage, DB size
- Funil de conversao (session -> login -> paywall -> checkout -> payment -> cancel)
- Features mais usadas, eventos por tipo
- Downloads de relatorios
- Top tickers por market cap, setores

### Horizon Terminal Access
- Tasks IA (sucesso, erros, tempo medio)
- Chat diario (mensagens, usuarios unicos)
- Documentos CVM por tipo
- Watchlist, logins diarios
- Perfil dos usuarios
