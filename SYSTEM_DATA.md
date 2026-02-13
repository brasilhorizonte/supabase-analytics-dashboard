# Brasil Horizonte - Dados Completos do Sistema

> Snapshot gerado em 2026-02-13

---

## Projetos Supabase

| Projeto | ID | Regiao | DB Size | Usuarios | Storage Objects |
|---------|-----|--------|---------|----------|-----------------|
| brasilhorizonte (BH) | `dawvgbopyemcayavcatd` | sa-east-1 | 320 MB | 73 | 40 |
| Horizon Terminal Access (HTA) | `llqhmywodxzstjlrulcw` | us-west-2 | 73 MB | 17 | 20,140 |

---

## BH - brasilhorizonte

### Visao Geral
- **Descricao**: Plataforma SaaS de analise fundamentalista de acoes brasileiras
- **Usuarios**: 73 registrados, 0 sessoes ativas no momento
- **Dados desde**: Perfis desde 2025-09-03, eventos desde 2026-01-07
- **Total de eventos**: 11,892 (20 tipos distintos)

### Assinantes (profiles)
| Status | Plano | Periodo | Qtd |
|--------|-------|---------|-----|
| free | free | - | 62 |
| inactive | free | - | 8 |
| active | fundamentalista | monthly | 2 |
| active | fundamentalista | yearly | 1 |

**Resumo**: 73 perfis, 2 ativos, 8 inativos, 62 free, 20 special_clients, churn rate 77.8%

### Eventos de Uso (usage_events)
| Evento | Contagem |
|--------|----------|
| feature_open | 8,439 |
| page_view | 2,370 |
| session_start | 444 |
| qualitativo_run | 161 |
| paywall_block | 127 |
| analysis_run | 82 |
| auth_login | 72 |
| checkout_start | 46 |
| report_view | 42 |
| feature_close | 30 |
| auth_logout | 14 |
| checkout_complete | 10 |
| payment_succeeded | 10 |
| valuai_analysis_start | 10 |
| fiscal_gate_complete | 9 |
| valuai_analysis_complete | 9 |
| report_download | 8 |
| subscription_cancel | 7 |
| asset_download | 1 |
| auth_password_reset_complete | 1 |

### Tabelas e Tamanhos
| Tabela | Rows | Tamanho |
|--------|------|---------|
| brapi_daily_prices | 1,163,177 | 219 MB |
| brapi_cashflows | 20,125 | 5,032 kB |
| brapi_income_statements | 19,815 | 7,712 kB |
| brapi_balance_sheets | 19,485 | 8,584 kB |
| usage_events | 11,892 | 9,416 kB |
| brapi_dividends | 7,384 | 2,360 kB |
| cvm_company_registry | 2,556 | 752 kB |
| batch_analysis_items | 1,314 | 400 kB |
| Qualitativo OLD | 614 | 12 MB |
| brapi_quotes | 331 | 3,200 kB |
| brapi_betas | 322 | 224 kB |
| Qualitativo | 205 | 5,256 kB |
| report_downloads | 196 | 144 kB |
| brapi_covariance_quotes | 162 | 264 kB |
| profiles | 73 | 128 kB |
| qualitativo_historico_old | 24 | 16 kB |
| mcp_session_cache | 18 | 96 kB |
| qualitativo_historico | 16 | 32 kB |
| research_reports | 14 | 32 kB |
| sectors | 13 | 48 kB |
| Dados_AreaCotista | 11 | 120 kB |
| content | 7 | 128 kB |
| companies | 6 | 48 kB |
| batch_analysis_runs | 4 | 64 kB |
| analysts | 3 | 48 kB |
| user_portfolios | 3 | 320 kB |
| gestao_carteiras | 2 | 64 kB |
| report_catalog | 1 | 32 kB |
| gestao | 0 | 24 kB |
| PUTesouro_import_Tesouro | 0 | - |
| m_v_brapi_dashboard | 331 | 304 kB |

### Schema das Tabelas Principais

#### profiles
```
id (uuid), user_id (uuid), full_name (text), company (text),
subscription_status (text), subscription_expires_at (timestamptz),
created_at (timestamptz), updated_at (timestamptz), is_admin (boolean),
stripe_customer_id (text), stripe_subscription_id (text),
plan (text), billing_period (text), is_special_client (boolean),
is_active (boolean), cpf (text), telefone (text), endereco (text),
municipio (text), uf (text), cep (text), fiscal_completed_at (timestamptz)
```

#### usage_events
```
id (uuid), user_id (uuid), event_name (text), feature (text),
action (text), success (boolean), duration_ms (integer),
properties (jsonb), event_ts (timestamptz), session_id (text),
anon_id (text), plan (text), subscription_status (text),
billing_period (text), is_admin (boolean), is_special_client (boolean),
account_created_at (timestamptz), route (text), page (text),
section (text), tab (text), referrer (text), landing_page (text),
utm_source (text), utm_medium (text), utm_campaign (text),
utm_term (text), utm_content (text), report_id (text),
content_id (text), company_id (text), sector_id (text),
analyst_id (text), ticker (text), portfolio_id (text),
device_type (text), os (text), browser (text), locale (text),
timezone (text), screen (text), latency_ms (integer),
error_code (text), result_count (integer)
```

#### brapi_quotes
```
ticker (text), symbol (text), price (numeric), market_cap (numeric),
adtv (numeric), regular_market_volume (numeric),
regular_market_change_percent (numeric), dividend_yield (numeric),
enterprise_value (numeric), ev_ebit (numeric), pl (numeric),
pvp (numeric), lpa (numeric), vpa (numeric), roe (numeric),
roic (numeric), net_margin (numeric), ebitda_margin (numeric),
profit_growth (numeric), revenue_growth (numeric),
debt_ebitda (numeric), liquidity_ratio (numeric),
name (text), sector (text), sub_sector (text),
long_name (text), short_name (text), industry (text),
website (text), logo_url (text), cnpj (text), cd_cvm (integer),
... (90+ colunas com dados financeiros detalhados)
```

#### brapi_daily_prices
```
ticker (text), trade_date (date), close (numeric),
adjusted_close (numeric), volume (numeric),
source (text), inserted_at (timestamptz), updated_at (timestamptz)
```

#### brapi_income_statements / brapi_cashflows / brapi_balance_sheets
Demonstracoes financeiras trimestrais e anuais por ticker.

#### Qualitativo
Analise qualitativa com scores em 6 categorias (C1-C6), cada uma com 6-11 perguntas com score e resposta textual.

#### companies / sectors / analysts / research_reports / content
Dados de conteudo editorial: empresas cobertas, setores, analistas, relatorios PDF e videos.

#### report_downloads
Tracking de downloads de relatorios por usuario.

### Edge Functions (BH)
| Funcao | Descricao |
|--------|-----------|
| stripe-webhook | Webhook Stripe para pagamentos/assinaturas |
| create-checkout-session | Cria sessao de checkout Stripe (JWT required) |
| create-portal-session | Portal de gerenciamento Stripe (JWT required) |
| delete-user | Deleta usuario e dados associados (JWT required) |
| update-quotes | Atualiza cotacoes brapi_quotes |
| update-daily-prices | Atualiza precos diarios brapi_daily_prices |
| update-dividends | Atualiza dividendos |
| fetch-brapi-quote | Busca cotacao individual da brapi |
| fetch-brapi-history | Busca historico de precos |
| fetch-financials | Busca demonstracoes financeiras |
| update-stocks | Atualiza dados de acoes |
| gemini-ai | Proxy para Gemini AI |
| extract-pdf-text | Extrai texto de PDFs |
| analyze-governance | Analise qualitativa de governanca via IA |
| batch-analyze-governance | Analise em batch de governanca |
| fetch-cvm-documents | Busca documentos CVM |
| sync-cvm-registry | Sincroniza registro de empresas CVM |
| save-qualitativo | Salva analise qualitativa |
| restore-qualitativo-old | Restaura analise qualitativa anterior |
| ianalista-mcp-context | Contexto MCP para iAnalista |
| thesis-validator | Validador de tese de investimento |
| webhook-snapshot | Webhook para snapshots |

---

## HTA - Horizon Terminal Access

### Visao Geral
- **Descricao**: Terminal de documentos CVM + agente IA para analise de acoes
- **Usuarios**: 17 registrados, 0 sessoes ativas no momento
- **Dados desde**: Eventos desde 2026-02-04, logins desde 2026-02-05
- **Documentos CVM**: 15,271
- **Empresas catalogadas**: 348

### Tabelas e Tamanhos
| Tabela | Rows | Tamanho |
|--------|------|---------|
| documents | 15,271 | 28 MB |
| document_files | 14,888 | 8,696 kB |
| terminal_events | 1,713 | 1,128 kB |
| companies | 348 | 296 kB |
| user_login_events | 187 | 120 kB |
| chat_messages | 160 | 344 kB |
| chat_sessions | 50 | 112 kB |
| user_profiles | 17 | 96 kB |
| user_daily_usage | 14 | 88 kB |
| proxy_daily_usage | 11 | 96 kB |
| user_watchlist | 10 | 80 kB |
| user_market_preferences | 3 | 64 kB |
| user_roles | 3 | 40 kB |
| org_members | 3 | 88 kB |
| org_document_events | 2 | 96 kB |
| org_documents | 2 | 160 kB |
| org_storage | 1 | 96 kB |
| orgs | 1 | 80 kB |
| cvm_status | 1 | 32 kB |
| chat_context | 0 | 40 kB |

### Schema das Tabelas Principais

#### documents
```
id (uuid), company_id (uuid), external_id (text, unique),
doc_type (text), title (text), summary (text),
document_date (date), source_url (text),
published_date (date), ai_summary (text), ai_summary_at (timestamptz),
created_at (timestamptz), updated_at (timestamptz)
```

#### document_files
```
id (uuid), document_id (uuid), bucket (text, default: 'company-documents'),
object_path (text), original_filename (text), mime_type (text),
size_bytes (bigint), checksum (text), is_primary (boolean),
created_at (timestamptz)
```

#### companies (HTA)
```
id (uuid), cvm_code (text, unique), ticker (text, unique),
name (text), sector (text), subsector (text), description (text),
governance_level (text), major_shareholders (jsonb),
bylaws_highlights (text[]), market_cap (text), logo_url (text),
created_at (timestamptz), updated_at (timestamptz)
```

#### terminal_events
```
id (uuid), event_ts (timestamptz), event_name (text),
feature (text), action (text), success (boolean),
user_id (uuid), session_id (text), ticker (text),
response_mode (text), duration_ms (integer), token_count (integer),
phase (text), error_message (text), properties (jsonb),
device_type (text), browser (text), os (text),
created_at (timestamptz)
```

#### chat_sessions
```
id (uuid), user_id (uuid), ticker (text),
title (text, default: 'Nova conversa'),
summary (text), expires_at (timestamptz, default: now() + 30 days),
created_at (timestamptz), updated_at (timestamptz)
```

#### chat_messages
```
id (uuid), session_id (uuid), role (text: user/assistant/system),
content (text), metadata (jsonb),
created_at (timestamptz)
```

#### user_profiles (HTA)
```
id (uuid), user_id (uuid, unique), full_name (text), cpf (text),
whatsapp (text), city (text), birth_date (date),
company (text), position (text),
client_type (enum: asset_gestora/family_office/consultoria/investidor_pf/outro),
accepted_terms (boolean), accepted_disclaimer (boolean),
status (enum: pending/approved/rejected),
approved_by (uuid), approved_at (timestamptz),
rejection_reason (text), email (text),
created_at (timestamptz), updated_at (timestamptz)
```

#### user_login_events
```
id (uuid), user_id (uuid), login_at (timestamptz),
ip_address (text), user_agent (text)
```

#### user_watchlist
```
id (uuid), user_id (uuid), ticker (text), created_at (timestamptz)
```

#### user_roles
```
id (uuid), user_id (uuid), role (enum: admin/user), created_at (timestamptz)
```

#### Organizacoes (orgs, org_members, org_storage, org_documents, org_document_events)
Sistema multi-tenant para gestoras/family offices com buckets de storage dedicados, controle de membros (owner/admin/member/viewer) e auditoria de eventos em documentos.

### Eventos do Terminal (terminal_events)
| Feature | Action | Eventos | Avg Duration |
|---------|--------|---------|--------------|
| agent | task_start | 346 | - |
| agent | task_end | 321 | - |
| session | start | 234 | - |
| chat | send | 180 | - |
| agent | plan_ready | 179 | - |
| tabs | open | 178 | - |
| agent | answer_done | 149 | 96,762 ms |
| chat | mode_change | 51 | - |
| agent | task_error | 24 | - |
| agent | workflow_error | 21 | - |
| tabs | close | 11 | - |
| chat | clear | 11 | - |
| agent | aborted | 7 | - |
| chat | rate_limit_exceeded | 1 | - |

### Edge Functions (HTA)
| Funcao | Descricao |
|--------|-----------|
| analytics-dashboard | API JSON do dashboard de analytics (auth admin) |
| dashboard-upload | Upload do frontend para Storage |
| cvm-upload | Upload de documentos CVM |
| cvm-status | Status do pipeline CVM |
| cvm-history | Historico de execucoes CVM |
| cvm-companies | Lista empresas CVM |
| cvm-run | Executa pipeline CVM |
| cvm-ingest | Ingestao de documentos CVM |
| cvm-ingest-history | Historico de ingestao CVM |
| gemini-proxy | Proxy para Gemini AI |
| anthropic-proxy | Proxy para Anthropic Claude |
| brapi-proxy | Proxy para API brapi |
| gemini-market-proxy | Proxy Gemini para dados de mercado |
| org-provisioning | Provisionamento de organizacoes |
| org-upload | Upload de docs para organizacoes |
| org-download | Download de docs de organizacoes |
| org-documents | CRUD de documentos organizacionais |
| org-members | Gerenciamento de membros |

---

## Dashboard de Analytics

### Arquitetura
```
Frontend (index.html)  -->  Edge Function (analytics-dashboard)  -->  RPC get_analytics_data()
  GitHub Pages               Projeto HTA                              BH + HTA (cross-project)
```

### Autenticacao
- Login via Supabase Auth (projeto HTA)
- Verificacao de admin via tabela `user_roles` com `role = 'admin'`
- Admins: lucasmello@brasilhorizonte.com.br, lucastnm@gmail.com, gabriel.dantas@brasilhorizonte.com.br

### API Response (get_analytics_data)

**BH retorna:**
- `overview`: total_users, active_sessions, storage_objects, db_size_bytes
- `daily_activity`: day, events, dau
- `usage_events_summary`: event_name, cnt
- `feature_usage`: feature, cnt
- `conversion_funnel`: sessions, logins, paywall_blocks, checkout_starts, payments, cancels
- `top_tickers_market`: ticker, sector, price, market_cap, dividend_yield, pl
- `sector_distribution`: sector, tickers
- `report_downloads_daily`: day, downloads
- `top_tickers_searched`: ticker, cnt
- `subscribers_overview`: total_profiles, active, inactive, free, special_clients, churn_rate
- `subscribers_by_plan`: plan, status, billing_period, cnt
- `signups_daily`: day, signups
- `subscription_events_daily`: day, paywall_blocks, checkout_starts, checkout_completes, payments, cancels
- `retention_cohorts`: cohort, cohort_size, retained_7d, retained_30d, retained_60d, retained_90d

**HTA retorna:**
- `overview`: total_users, active_sessions, storage_objects, db_size_bytes
- `terminal_daily`: day, sessions, tasks, chat_msgs
- `terminal_events_summary`: feature, action, event_count, avg_duration_ms
- `chat_daily`: day, messages, unique_users
- `documents_by_type`: doc_type, total
- `watchlist`: ticker
- `user_profiles_summary`: status, client_type, cnt
- `login_daily`: day, logins, unique_users
- `top_tickers_searched`: ticker, cnt

### Abas do Dashboard
1. **Visao Geral**: KPIs combinados (DB, usuarios, sessoes, storage, assinantes ativos, taxa conversao), charts de eventos/DAU BH, sessoes/tasks/chat HTA, signups, tabela comparativa
2. **brasilhorizonte**: KPIs BH, eventos/DAU diarios, funil de conversao, uso de recursos, eventos resumidos, downloads de relatorio, tickers buscados, secao Assinantes & Retencao (5 KPIs, 6 charts, tabela de retencao por coorte)
3. **Horizon Terminal**: KPIs HTA, sessoes/tasks/chat diarios, mensagens e usuarios unicos, logins, tickers buscados, documentos por tipo, watchlist, tabela de eventos, perfis de usuario

### Filtros
- Granularidade: Diario / Semanal / Mensal (todas as abas)
- Date range: De / Ate (todas as abas)
- Plano: Todos / Essencial / Fundamentalista / iAnalista / Valor (secao assinantes BH)
- Periodo: Todos / Mensal / Anual / Vitalicio (secao assinantes BH)

---

## Notas Tecnicas Importantes

### Nomes de colunas reais (diferem dos migrations originais)
- BH `usage_events`: usa `event_ts` (NAO `created_at`) para timestamp
- HTA `chat_messages`: NAO tem `user_id` - deve fazer JOIN com `chat_sessions`
- HTA login events: tabela `user_login_events` (NAO `login_events`), usa `login_at`
- HTA `proxy_daily_usage`: usa `usage_date` (date, NAO timestamp), tem `request_count` (usar SUM)
- HTA documentos CVM: tabela `documents` (NAO `cvm_documents`)
- HTA watchlist: tabela `user_watchlist` (NAO `watchlist`)
- HTA `terminal_events`: tem tanto `event_ts` quanto `created_at`
- BH evento de pagamento: `payment_succeeded` (NAO `payment_success`)

### Stack
- **Runtime**: Deno (Supabase Edge Functions)
- **Frontend**: HTML/CSS/JS vanilla + Chart.js 4.4.1
- **Auth**: Supabase Auth (email/password)
- **DB**: PostgreSQL (via Supabase)
- **Hosting**: GitHub Pages
- **Pagamentos**: Stripe (checkout, webhooks, portal)
- **IA**: Gemini AI + Anthropic Claude (via proxies)
- **Dados de mercado**: brapi API
- **Documentos**: CVM (pipeline automatizado)
