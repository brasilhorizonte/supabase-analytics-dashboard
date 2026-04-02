# Guia de Desenvolvimento

## Pre-requisitos

- Supabase CLI (para deploy de Edge Functions e migrations)
- Acesso admin aos projetos BH (`dawvgbopyemcayavcatd`) e HTA (`llqhmywodxzstjlrulcw`)
- Git + GitHub (para deploy do frontend via Pages)

## Setup do Ambiente

1. Clonar o repositorio:
```bash
git clone https://github.com/brasilhorizonte/supabase-analytics-dashboard.git
cd supabase-analytics-dashboard
```

2. Configurar variaveis de ambiente:
```bash
cp .env.example .env
# Editar .env com as chaves reais
```

## Desenvolvimento Local

### Frontend
O frontend e um unico `index.html`. Abra diretamente no browser ou use um servidor HTTP:
```bash
python3 -m http.server 8888
# Acessar http://localhost:8888/index.html
```

**Nota:** O login requer CORS com o Supabase Auth, entao a autenticacao so funciona quando hospedado no dominio correto (GitHub Pages) ou com proxy local.

### Backend (Edge Function)
```bash
# Testar API (substitua TOKEN pelo access_token do Supabase Auth)
curl -H "Authorization: Bearer TOKEN" \
  https://llqhmywodxzstjlrulcw.supabase.co/functions/v1/analytics-dashboard
```

## Deploy

### Frontend (GitHub Pages)
```bash
git add index.html
git commit -m "feat: descricao da mudanca"
git push origin main
# GitHub Pages atualiza automaticamente
```

### Frontend (Supabase Storage — alternativo)
```bash
./deploy.sh   # Pede a Service Role Key do projeto HTA
```

### Edge Function
```bash
supabase functions deploy analytics-dashboard \
  --project-ref llqhmywodxzstjlrulcw \
  --no-verify-jwt
```

### Migrations (SQL)
```bash
# Aplicar no BH
supabase db push --project-ref dawvgbopyemcayavcatd

# Aplicar no HTA
supabase db push --project-ref llqhmywodxzstjlrulcw
```

**Alternativa:** Usar Supabase MCP `execute_sql` para aplicar SQL diretamente.

### Proxies (Edge Functions externas)
Os proxies (gemini, anthropic, openai, brapi, etc.) sao gerenciados separadamente via Supabase MCP/CLI:
```bash
supabase functions deploy <proxy-name> \
  --project-ref llqhmywodxzstjlrulcw \
  --no-verify-jwt
```

Estrutura de deploy:
```
functions/<proxy-name>/index.ts
functions/_shared/cors.ts
functions/_shared/supabase.ts
```

## Testes

Nao ha framework de testes automatizados. Verificacao e feita manualmente:
1. Abrir dashboard no browser
2. Verificar que todos os charts/tabelas renderizam
3. Testar filtros globais (7d, 30d, 90d)
4. Verificar responsivo mobile

## Estrutura do Codigo Frontend

O `index.html` segue este padrao para cada tab:
```javascript
function renderXxxYyy() {
    const data = dashboardData.xxx;
    const f = globalFilters;
    buildHTML('tabId', `...${canvasHTML('chartId','Titulo')}...`);
    // Logica de charts e tabelas
}
```

Helpers disponiveis: `fmt()`, `pct()`, `canvasHTML()`, `buildHTML()`, `destroyChart()`, `makeSortable()`, `prepareTimeSeries()`, `prepareMultiCategoryTS()`, `filterSnapshot()`.

## Logs

```bash
# Ver logs da Edge Function
supabase functions logs analytics-dashboard --project-ref llqhmywodxzstjlrulcw
```

Ultima atualizacao: 2026-04-01
