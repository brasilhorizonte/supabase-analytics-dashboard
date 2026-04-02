# Arvore de Codigo — Source Tree Analysis

```
supabase-analytics-dashboard/
├── index.html                          # Frontend SPA (login + dashboard + Chart.js) ~155KB
├── deploy.sh                           # Script de deploy para Supabase Storage
├── CLAUDE.md                           # Documentacao tecnica detalhada do projeto
├── README.md                           # README do repositorio
├── SYSTEM_DATA.md                      # Dados do sistema
├── platforms.md                        # Documentacao de plataformas
├── .env.example                        # Template de variaveis de ambiente
├── .gitignore                          # Git ignore
│
├── supabase/                           # Configuracao e funcoes Supabase
│   ├── config.toml                     # Config do projeto (project_id HTA, verify_jwt)
│   └── functions/
│       └── analytics-dashboard/
│           └── index.ts                # Edge Function — API JSON com auth admin (Deno)
│   └── migrations/                     # SQL migrations (RPCs, tabelas, funcoes)
│       ├── 20260212_*_brasilhorizonte.sql     # RPC get_analytics_data() no BH
│       ├── 20260212_*_horizon_terminal.sql    # RPC get_analytics_data() no HTA
│       ├── 20260216_enhance_token_analytics.sql
│       ├── 20260226_fix_token_tracking.sql
│       ├── 20260226_add_error_metrics.sql
│       ├── 20260227_add_iacoes_referrer_tracking.sql
│       ├── 20260301_filter_non_ai_proxies.sql
│       └── 20260401_dashboard_reformulation.sql
│
├── _bmad/                              # BMad project management (v6.2.2)
│   ├── project-context.md              # Regras criticas para agentes IA
│   ├── core/                           # Modulo core BMad (skills basicas)
│   ├── bmm/                            # BMad Method Module (workflows avancados)
│   └── _config/                        # Configuracao e manifestos
│
├── docs/                               # Documentacao gerada (este diretorio)
│   ├── index.md                        # Indice principal
│   ├── project-overview.md             # Visao geral do projeto
│   ├── source-tree-analysis.md         # Este arquivo
│   ├── development-guide.md            # Guia de desenvolvimento
│   ├── data-models.md                  # Modelos de dados e RPCs
│   └── api-contracts.md                # Contratos de API
│
└── .claude/                            # Configuracao Claude Code
    ├── plans/                          # Planos de implementacao
    └── skills/                         # Skills BMad instaladas
```

## Diretorios Criticos

| Diretorio | Proposito |
|-----------|-----------|
| `/` (raiz) | `index.html` e o unico arquivo frontend — SPA inline |
| `supabase/functions/analytics-dashboard/` | Edge Function API — unico endpoint backend |
| `supabase/migrations/` | Historico de SQL migrations (RPCs, tabelas) |
| `_bmad/` | Gestao de projeto BMad — nao afeta runtime |
| `docs/` | Documentacao gerada — nao afeta runtime |

## Pontos de Entrada

| Tipo | Arquivo | Descricao |
|------|---------|-----------|
| Frontend | `index.html` | SPA completo (HTML + CSS + JS inline) |
| Backend | `supabase/functions/analytics-dashboard/index.ts` | API REST que retorna JSON |

## Nota

Este projeto nao tem `package.json`, `node_modules`, ou build step. O frontend e um unico arquivo HTML com CSS e JS inline. O backend usa Deno via Supabase Edge Functions.

Ultima atualizacao: 2026-04-01
