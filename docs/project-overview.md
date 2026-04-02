# Supabase Analytics Dashboard — Visao Geral

## Resumo

Dashboard de analytics em tempo real para os projetos **brasilhorizonte** (BH) e **Horizon Terminal Access** (HTA) da Brasil Horizonte. Exibe metricas de uso, engajamento, retencao, custos e detalhes de ambas as plataformas, alem de analytics do site iAcoes.

## Classificacao

| Atributo | Valor |
|----------|-------|
| Tipo de repositorio | Monolith |
| Tipo de projeto | Web (SPA) + Backend (Edge Function) |
| Linguagem principal | JavaScript/TypeScript |
| Framework | Nenhum (vanilla JS) |
| Build step | Nenhum |
| Hospedagem | GitHub Pages (frontend), Supabase Edge Functions (API) |

## Stack Tecnologica

| Categoria | Tecnologia | Versao | Descricao |
|-----------|-----------|--------|-----------|
| Frontend | HTML/CSS/JS | Vanilla | SPA inline, sem framework |
| Charts | Chart.js | 4.4.1 | CDN (cdnjs.cloudflare.com) |
| Runtime | Deno | Latest | Supabase Edge Functions |
| Database | PostgreSQL | Supabase-managed | 2 projetos separados |
| Auth | Supabase Auth | - | email/password |
| Deploy | GitHub Pages | - | Push para main |
| Deploy API | Supabase CLI | - | `supabase functions deploy` |

## Projetos Supabase

| Projeto | ID | Regiao | Descricao |
|---------|-----|--------|-----------|
| brasilhorizonte (BH) | `dawvgbopyemcayavcatd` | sa-east-1 | Plataforma SaaS de analise fundamentalista |
| Horizon Terminal Access (HTA) | `llqhmywodxzstjlrulcw` | us-west-2 | Terminal de documentos CVM + agente IA |

## Arquitetura

```
[Browser] --HTTPS--> [GitHub Pages: index.html]
                          |
                          | fetch JSON
                          v
              [Supabase Edge Function: analytics-dashboard]
                     /            \
                    v              v
        [BH Supabase DB]    [HTA Supabase DB]
        (REST API + RPC)     (Direct + RPC)
```

- Frontend faz uma unica chamada a Edge Function
- Edge Function verifica JWT + role admin
- Busca dados de ambos os projetos via `get_analytics_data()` RPC
- Retorna JSON consolidado, frontend filtra/agrega localmente

## Documentacao Relacionada

- [Indice](./index.md) — Ponto de entrada principal
- [Arvore de Codigo](./source-tree-analysis.md) — Estrutura de arquivos anotada
- [Guia de Desenvolvimento](./development-guide.md) — Setup e comandos
- [Modelos de Dados](./data-models.md) — Schema e RPCs
- [Contratos de API](./api-contracts.md) — Endpoints e auth

Ultima atualizacao: 2026-04-01
