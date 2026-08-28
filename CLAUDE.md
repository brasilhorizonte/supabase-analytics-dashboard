# iAcoes Analytics Dashboard

Dashboard de analytics em tempo real para os projetos **brasilhorizonte** (UI: "iAcoes") e **Horizon Terminal Access** da Brasil Horizonte.

> **Nota de branding (2026-04-25):** O dashboard foi renomeado de "Brasil Horizonte / BH" para "iAcoes" apenas em UI/labels (sidebar, titulo, tabs). Variaveis JS internas (`bhData`, `bhSubFilters`, `renderBh*`), IDs de elementos (`bhVisao`, `bhEngajamento`...) e chaves do response da Edge Function (`bh: {...}`) **continuam usando o prefixo `bh`** para preservar compatibilidade.

## Arquitetura

O projeto tem duas camadas separadas:

1. **Frontend** (`index.html`): Single-page app com login, sidebar lateral dark com grupos colapsaveis por plataforma (iAcoes: 8 sub-abas, Horizon Terminal: 6 sub-abas, Landing iAcoes standalone), area de conteudo light, filtros globais. Hospedado como arquivo estatico (GitHub Pages ou Supabase Storage). Nao usa framework — tudo inline (CSS + JS).

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
- **Chamadas RPC ao BH usam service_role do BH** (2026-05-22): apos hardening de seguranca em 2026-05-12 (migration `20260512230000_remediate_security_views.sql`), as RPCs analytics no BH passaram a nao conceder `EXECUTE` para `anon`. A Edge Function le `BH_KEY = Deno.env.get("BH_SERVICE_ROLE_KEY") || Deno.env.get("CVM_SERVICE_ROLE_KEY")` (ambas configuradas como secrets no projeto HTA). Nenhuma mudanca de seguranca foi feita no projeto BH para destravar o dashboard.

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
    20260430_iacoes_daily_breakdowns.sql    # NEW RPC get_analytics_data_iacoes_daily() — 8 daily breakdowns p/ filtro temporal
    20260501_bh_oauth_metrics.sql           # NEW RPC get_analytics_data_bh_oauth() — Google OAuth adoption (auth_login + profile_type)
    20260503_bh_engagement_v2_admin_filter.sql # View usage_events_clean + RPC get_analytics_data_bh_extras_v2(p_from, p_to) — admin filter, period window, lifetime fix
    20260527_bh_engagement_ticker_v3.sql    # NEW RPC get_analytics_data_bh_tickers_v3() — top N dinamico no periodo + multi-select + admin toggle
    20260622_airton_whatsapp.sql            # Estende airton_v2 (blocos WhatsApp) + NEW RPC get_analytics_data_airton_whatsapp_v1() — canal WhatsApp do Airton (cutover TG->WA 10/06)
    20260817_dashboard_overhaul_bh.sql      # Overhaul: v2_impl sem 8 secoes mortas, NEW get_notification_analytics_v2(p_from,p_to), utm_v2 sem 50OFF, statement_timeout nas 5 RPCs restantes
    20260818_v2_impl_timeout_90s.sql        # Fix preset Max sem dados (57014): timeout real era 8s da role authenticator (SET em nivel de funcao e inerte no path REST); fix = ALTER ROLE service_role SET statement_timeout='90s'
    20260828_bh_email_analytics_v1.sql      # Taxonomia de email (3 funcoes IMMUTABLE) + NEW RPC get_analytics_data_bh_email_v1() — aba Emails com atribuicao de clique por UTM
```

## Overhaul de Performance & Histórico (2026-08-17)

Reforma geral para resolver: (1) histórico incompleto (default 30d sem preset "Máx", notificações travadas em 90d hardcoded), (2) lentidão (2 fetches completos no login, ~148 charts renderizados de uma vez, RPC base com seções mortas), (3) seções irrelevantes (market cap de tickers, campanha 50OFF expirada, `geo` nunca consumido).

- **Migration `20260817_dashboard_overhaul_bh.sql`** (aplicada no BH via MCP em 2026-08-17):
  - `get_analytics_data_v2_impl` (o corpo real; `get_analytics_data_v2` é só wrapper de auth): **removidas 8 seções** — `top_tickers_market` e `sector_distribution` (liam `brapi_quotes`, market data irrelevante e já quebrado no frontend) + as 6 seções de ticker (`ticker_by_feature`, `ticker_trend_daily`, `feature_usage_trend`, `ticker_ranking`, `user_ticker_usage`, `user_ticker_detail`) que eram 100% descartadas no merge por `get_analytics_data_bh_tickers_v3`. Tempo warm 30d: 4,6s → **3,7s**. Restam 61 chaves.
  - **NOVA `get_notification_analytics_v2(p_from, p_to)`**: v1 tinha `interval '90 days'` hardcoded em 4 séries daily — dados >90d nunca apareciam. v2 janela as seções event-based (`notifications_by_type_daily`, `notifications_delivery`, `notifications_delivery_daily`, `notifications_top_tickers`, `telegram_links_daily` e contadores event-based do `notification_funnel`); snapshots de estado (`telegram_overview`, `notification_prefs_summary`, `notification_type_popularity`) continuam all-time. Mesmas chaves da v1; v1 preservada.
  - `get_analytics_data_bh_utm_v2`: removidas as 3 seções da campanha 50OFF (expirada em 05/2026) e as constantes `promo_start`/`promo_end`.
  - `statement_timeout='30s'` aplicado às 5 RPCs que faltavam: `bh_pool_v2`, `bh_tickers_v3`, `airton_telegram_v1`, `airton_whatsapp_v1`, `get_geo_profiles`.
- **Edge Function**: chamadas `get_geo_profiles` (BH+HTA) removidas (payload morto, chave `geo` saiu do response); `get_notification_analytics` → `get_notification_analytics_v2` com `{p_from, p_to}`; datas inválidas em `?from`/`?to` agora caem no default em vez de 500; falha de `fetchRpc` loga `console.error` (antes era silenciosa).
- **Frontend**:
  - Presets **180d** e **Máx** (Máx = from `2026-01-07`, primeiro evento registrado — constante `MAX_PRESET_FROM`).
  - **Fetch único no login** (antes eram 2 payloads completos: fetch sem params + `applyPreset(30)` refetchava tudo).
  - **Render lazy por aba**: `dirtyTabs` Set — só a aba atual renderiza no login/refetch; as outras renderizam ao serem visitadas (antes: 14 abas / ~148 charts de uma vez).
  - Auto-refresh de 5min pula quando `document.hidden`.
  - `pruneDetachedCharts()`: destrói instâncias de Chart.js cujo canvas saiu do DOM (vazamento de ~30 charts órfãos por troca de período); resize pós-switchTab só nos charts da aba ativa.
  - **Timezone**: `from`/`to` enviados como `T00:00:00-03:00`/`T23:59:59.999-03:00` (antes UTC `Z`, cortava 3h nas bordas — RPCs agregam em America/Sao_Paulo).
  - Removidos: tabela "Top Tickers (Market Cap)" + doughnut "Distribuicao por Setor" (bhDetalhes), bloco "Campanha 50OFF" (bhAquisicao), gráfico duplicado `bhAqSignupsChart` (igual ao da Visão Geral), leitura morta de `dashboardData.geo`.
- **Não feito nesta fase** (candidatos futuros): rewrite da `get_analytics_data_v2_impl` com CTEs compartilhadas (os 3,7s restantes são ~55 seções × ~65ms — sem baleia individual; stickiness 76ms, retention_cohorts 290ms); parametrizar `get_analytics_data` do HTA (hoje all-time, mas rápida ~135ms — o recorte é client-side e o histórico completo já trafega); consolidar duplicatas HTA (login chart em 3 abas).
- **Nota**: seções ainda all-time por design (KPIs de estado): `overview`, `subscribers_*`, `mrr_estimate`, `revenue_by_plan*`, `user_inactivity`, `activation_*`, `time_to_convert`, `watchlist_summary` — não reagem ao filtro de período.

## BH Engagement — Ticker Analytics v3 (2026-05-27)

Reformulação das 6 seções de ticker da aba Engajamento iAções (`ticker_by_feature`, `ticker_trend_daily`, `feature_usage_trend`, `ticker_ranking`, `user_ticker_usage`, `user_ticker_detail`). Bugs corrigidos:

1. **Top N estatico** — Em `get_analytics_data_v2()`, o CTE `top_tickers` calculava o top 30 **all-time** (sem `p_from`/`p_to`). Resultado: trocar de janela nao mudava quais tickers apareciam. v3 calcula o top N dentro do periodo.
2. **Ranking e tabelas all-time** — `ticker_ranking`, `user_ticker_usage`, `user_ticker_detail` ignoravam o filtro global. v3: todos filtrados por periodo.
3. **Metricas conflitantes** — `feature_usage_trend` plotava `unique_users` enquanto `ticker_trend_daily` plotava `cnt`. Nunca batiam. Pior: `feature_usage_trend` exigia `ticker IS NOT NULL`, entao Macro Beta/Optimizer sumiam. v3 retorna AMBOS `cnt` e `unique_users` por dia/feature, e remove o filtro de ticker.
4. **Admins inflavam tudo** — Nenhuma das 6 secoes usava `usage_events_clean`. v3 aplica filtro inline via `profiles.is_admin` (padrao Airton v2.3) com toggle `p_include_admins`.
5. **`user_ticker_detail` desperdicado** — A RPC v2 ja retornava (user x ticker x feature) mas o frontend nunca renderizava. v3 limita a 5000 linhas e o frontend agora exibe via drill-down expandindo cada linha da tabela.

- **Nova RPC** `get_analytics_data_bh_tickers_v3(p_from timestamptz, p_to timestamptz, p_include_admins boolean DEFAULT false, p_tickers text[] DEFAULT NULL, p_top_n int DEFAULT 30)` em migration `20260527_bh_engagement_ticker_v3.sql`. Defaults: ultimos 30 dias, sem admins, top 30 dinamico. Quando `p_tickers` e nao-nulo, ignora top N e retorna so esses tickers (sem linha 'Outros').
- **Edge function**: 13o `fetchRpc` em paralelo no `Promise.all`. Aceita query params `?bh_ticker_include_admins=1`, `?bh_tickers=PETR4,VALE3` (CSV), `?bh_top_n=30`. Merge no `bhMerged` em ULTIMO (sobrescreve as 6 secoes vindas de v2).
- **Frontend** (`index.html`): nova sub-bar de controles em `renderBhEngajamento` (multi-select de tickers com busca, toggle metrica Rodadas/Usuarios unicos, toggle Incluir admins). Estado em `window._bhTickerFilters = { selected, includeAdmins, metric }`. `fetchAnalytics()` envia os 3 params. `renderUserTickerTable` agora aceita `detailRows` (de `bh.user_ticker_detail`) e renderiza expansao por linha. Toggle metrica e client-side (nao refetcha); toggle admin e multi-select disparam `refetchAndRerender()`.
- **v2 nao foi alterada** — `get_analytics_data_v2()` continua retornando as 6 secoes (rollback gratuito), apenas deixou de ser fonte no frontend.

## Emails — aba dedicada (2026-08-28)

Nova sub-aba **"Emails"** no grupo iAcoes (entre Airton e Retencao). Substitui a secao "Comunicacao outbound" da aba Detalhes, que renderizava `email_type` cru — 37 valores distintos, sem taxonomia, sem nenhuma metrica de performance.

### Nao existe taxa de abertura

`email_log` tem apenas `(recipient_*, email_type, subject, content_*, status, error_message, metadata, sent_by, created_at)` — **sem `opened_at`/`clicked_at`**. Nao ha pixel de rastreio, nao ha tabela de eventos do provedor e nenhuma das ~20 edge functions `send-*` do BH recebe webhook (a unica tabela `webhook_events` e do Stripe). Portanto **open rate e impossivel com os dados atuais** — o dashboard diz isso explicitamente num aviso no topo da aba, em vez de inventar um numero.

O proxy disponivel e o **clique**, reconstruido por UTM. Para ter open rate de verdade seria preciso: criar uma edge function `resend-webhook` no BH, registrar o endpoint no provedor e persistir `email.opened` / `email.clicked` / `email.bounced` numa tabela nova (ex: `email_events`), depois estender a RPC. Nao foi feito (mexe no projeto BH, fora deste repo).

### Atribuicao de clique (cuidado com a UTM sticky)

`usage_events` guarda `utm_*` de forma **sticky**: a UTM da sessao e reemitida em todo evento seguinte, por meses. Ex: `weekly_cvm_digest_2026W19` tem **9.134 eventos para 7 usuarios**, com span medio de 27 dias (um caso chega a 93 dias). Contar eventos — ou contar sessoes com UTM de email — superestima em ~10x.

O modelo correto, implementado na RPC:
- **Clique** = `min(event_ts)` por `(user_id, utm_campaign)`, so valendo se ocorreu **depois** do envio e dentro de **30 dias**.
- **Sessao de clique** = apenas a **primeira** sessao por `(user_id, campanha)` (`DISTINCT ON`). As seguintes sao carryover.
- Chave de match: os 3 valores `metadata->>'utm_campaign'`, `metadata->>'campaign'` e `email_type` — juntos cobrem **17/17** das `utm_campaign` de email observadas (nenhum sozinho cobre tudo: digests usam `utm_campaign` datado, catchbacks so batem por `email_type`).
- Como so links com UTM sao rastreados, **o CTR e um piso**, nao o valor real. A UI rotula assim.

### Taxonomia (3 eixos)

3 funcoes `IMMUTABLE` reutilizaveis mapeiam os 37 `email_type` em:

| Eixo | Valores |
|------|---------|
| `bh_email_category()` | digest, onboarding, trial, dunning, winback, activation, community, announcement, content, manual, other |
| `bh_email_cadence()` | recorrente (digests), automatico (gatilho de ciclo de vida), campanha (blast), manual |
| `bh_email_stage()` | ativacao, engajamento, retencao, monetizacao, outro |

A ordem das clausulas importa: `trial_launch_announcement` cai em `announcement` (nao em `trial`) porque os padroes `trial_ending%`/`trial_ended%` sao testados antes e nao casam com ele.

### RPC

`get_analytics_data_bh_email_v1(p_from timestamptz, p_to timestamptz, p_include_admins boolean DEFAULT false)` — defaults: ultimos 30 dias, sem admins (filtro por `profiles.is_admin` sobre `recipient_user_id`). `statement_timeout='30s'`; roda em ~420ms no periodo Max. Retorna 17 chaves: `email_overview`, `email_by_category`, `email_by_cadence`, `email_by_stage`, `email_by_type`, `email_campaigns`, `email_daily`, `email_click_funnel`, `email_time_to_click`, `email_domains`, `email_subject_source`, `email_frequency`, `email_top_recipients`, `email_failures`, `email_send_hour`, `email_optin`, `email_by_tier`, `meta`.

- **Edge function**: 13o `fetchRpc` no `Promise.all`. Novo query param `?email_include_admins=true`. A chave `meta` da RPC e renomeada para `email_meta` **antes** do merge — varias RPCs devolvem `meta` e o spread faria a ultima sobrescrever as outras.
- **Frontend**: `renderBhEmails()` + constantes `EMAIL_CAT_LABELS`/`EMAIL_CAT_COLORS`/`EMAIL_CADENCE_LABELS`/`EMAIL_STAGE_LABELS` e helper `emailCatBadge()`. Estado do toggle em `window._emailIncludeAdmins`; `fetchAnalytics()` le esse flag. O funil usa escala logaritmica (vai de milhares de envios a unidades de pagamento).
- **Detalhes**: a secao virou "Comunicacao outbound (WhatsApp)". As chaves `email_log_daily`/`email_log_summary` continuam vindo de `get_analytics_data_bh_extras_v2` mas **nao sao mais renderizadas** — elas incluem admins e nao classificam nada, entao mostrar as duas versoes lado a lado dava numeros divergentes.

### Achados na primeira leitura (periodo Max, sem admins)

- 7.643 envios, 449 destinatarios, **17 emails por pessoa** — 247 pessoas na faixa 11-30 emails.
- CTR rastreado por categoria: **winback 2,53%** (melhor), community 0,81%, digest 0,59%, announcement 0,12%, **onboarding/trial 0%** (os emails de welcome e trial nao tem UTM nos links — nao da pra medir, nao que ninguem clique).
- **Assunto gerado por IA rende ~2x o estatico**: 0,73% vs 0,40% de CTR nos digests.
- Mediana ate o primeiro clique: 3,1h.

## Airton Analytics (2026-05-12)

Nova sub-aba "Airton" no grupo iAcoes (entre Engajamento e Retencao) com tracking completo do chat conversacional Airton (lancado no app iAcoes em `/Users/gdamelo/dashbrasilhorizonte`) — incluindo canal Telegram via `@IAnalistaBH_bot`.

- **Fontes de dados** (todas no projeto BH):
  - `usage_events` (event_name `companion_*`): eventos web emitidos por `useCompanion.ts` e `CompanionChat.tsx` — `companion_opened`, `companion_session_closed`, `companion_first_user_message`, `companion_message_sent` (success/error), `companion_tool_call` (success/empty/error com `tool_name` em properties), `companion_tool_called`, `companion_telegram_cta_clicked`/`_dismissed`
  - `usage_events` (event_name `gemini_token_usage`, `action=companion`): tokens logados pela Edge Function `gemini-ai` no projeto BH (`logGeminiTokenUsage` em `gemini-ai/index.ts:3560`) — properties contem `model_used`, `input_tokens`, `cached_tokens`, `output_tokens`, `thoughts_tokens`, `total_tokens`, `tool_calls_used`, `finish_reason`. **Diferente do HTA**, que usa `server_token_usage`.
  - `companion_messages` (com `source` text `web`/`telegram`/`system`): unica fonte das mensagens via Telegram, ja que o `companion-telegram-receiver` nao emite `usage_events`
  - `companion_threads` (com `last_user_source` `web`/`telegram`): stats de threads
- **Nova RPC** `get_analytics_data_airton_v2(p_from timestamptz, p_to timestamptz)` (migration `20260512_airton_analytics.sql`). Defaults: ultimos 30 dias. Aplica filtro de admin via `usage_events_clean` (para usage_events) e JOIN `auth.users` (para companion_messages/threads). Retorna 14 secoes:
  - `airton_overview`: KPIs agregados (total/success/error msgs, error_rate, unique_users, sessions opened/closed, first_messages, tool_calls, requests_with_tokens, input/cached/output/thoughts/total tokens, telegram_users/messages/share_pct)
  - `airton_daily`: serie diaria — messages_success/error, tool_calls, first_messages, sessions_opened, unique_users
  - `airton_funnel`: usuarios unicos por etapa (opened -> first_message -> tool_called -> message_sent -> session_closed + abandoned_at_greeting)
  - `airton_token_daily`: tokens por dia x model_used
  - `airton_token_summary`: tokens por model_used + avg_total_per_request
  - `airton_token_last_24h`: snapshot 24h
  - `airton_context_top`: top 30 combinacoes section/tab/ticker
  - `airton_tool_top`: top 20 tools por nome (de `properties.tool_name` em `companion_tool_call`) com success/empty/errors/unique_users
  - `airton_tool_calls_daily`: tool calls por dia (success/empty/errors)
  - `airton_threads_overview`: threads_created, threads_active, avg_messages_per_thread, threads_last_source_web/telegram
  - `airton_telegram_overview`: tg_unique_users, tg_user/model_messages, tg_threads_active, users_tg_only / web_only / web_and_tg
  - `airton_telegram_daily`: mensagens TG por dia
  - `airton_telegram_cta_funnel`: cta_clicked/dismissed + unique_clickers
  - `airton_errors_recent`: erros por dia + top error_code
  - `meta`: `{from, to, admins_excluded: 3, source}`
- **Edge function**: `analytics-dashboard/index.ts` agora chama 10 RPCs em paralelo (10º = `get_analytics_data_airton_v2`); merge em `bhMerged`.
- **Frontend** (`index.html`): nova funcao `renderBhAirton()` com Hero KPIs (8 cards incluindo custo USD estimado client-side), atividade diaria, funil, bloco de tokens (4 KPIs + daily stacked por modelo + requests por modelo + tabela com custo por modelo), top tools, top contextos, threads, bloco "Airton via Telegram" (7 KPIs + daily + CTA chart) e erros recentes. Mini-secao "Companion (IAnalista)" antiga em `renderBhEngajamento` removida — dados consolidados na nova aba.
- **NAO migrado nesta fase**: `get_analytics_data.companion_messages_daily` (v1, all-time, inclui admins) continua existindo na RPC base mas nao e mais consumido pelo frontend.

## Airton — canal WhatsApp (2026-06-22)

WhatsApp **substituiu o Telegram** como canal ativo do Airton em **2026-06-10** (o Telegram parou de receber mensagens exatamente quando o WhatsApp comecou). `companion_messages` agora recebe `source='whatsapp'` e ha um funil rico de eventos `whatsapp_*` em `usage_events`. Bloco "Airton via WhatsApp" adicionado na aba Airton com **paridade ao Telegram**, posicionado **antes** dos blocos Telegram (WhatsApp = ativo, Telegram = legado).

- **Extensao de `get_analytics_data_airton_v2`** (migration `20260622_airton_whatsapp.sql`, bump para `airton_v2.4_whatsapp_20260622`): assinatura **inalterada** `(p_from, p_to, p_include_admins)`. Espelha os blocos de mensagens Telegram via o mesmo CTE `cm` (que ja respeita o toggle de admins por `profiles.is_admin`). Novas chaves:
  - `airton_whatsapp_overview`: wa_unique_users, wa_user/model/total_messages, wa_threads_active, users_wa_only / web_only / web_and_wa
  - `airton_whatsapp_daily`: mensagens WA por dia (user/model/total/unique_users)
  - `airton_overview` ganhou `whatsapp_users`, `whatsapp_messages`, `whatsapp_share_pct`
  - `airton_threads_overview` ganhou `threads_last_source_whatsapp`
- **Nova RPC complementar** `get_analytics_data_airton_whatsapp_v1(p_from timestamptz, p_to timestamptz)` (mesma migration). Espelho de `get_analytics_data_airton_telegram_v1`, le de `usage_events_clean` (admins ja excluidos pela view; sem toggle). Retorna:
  - `airton_whatsapp_linking_funnel`: offer_shown → connect_clicked → token_generated → token_copied → bot_link_clicked → link_received → verify_clicked → linked + unlinked + optout (usuarios unicos)
  - `airton_whatsapp_offers`: offer_shown/clicked/dismissed/token_refreshed + unique_shown/unique_clickers
  - `airton_whatsapp_funnel_daily`: serie diaria das etapas-chave
  - `airton_whatsapp_features`: briefing_request/delivered, cvm_pdf_request/open_request (+ unique users)
  - `airton_whatsapp_message_outcomes`: success/empty_response/failed/total de `whatsapp_message_received` + `avg_latency_ms` (de `whatsapp_gemini_latency_ms.ms`) + fallback_recovery_shown + thread_reset
  - `airton_whatsapp_migration`: whatsmoved_viewed + tg_invite_sent (sinal de migracao TG→WA)
  - `meta`: `{from, to, rpc_version: 'airton_whatsapp_v1', source: 'usage_events_clean'}`
  - **Nota de schema** (verificado 2026-06-22): `whatsapp_token_generated` tem `success = NULL` (NAO filtrar por `success`, diferente do `telegram_token_generated`). `whatsapp_message_received` usa coluna booleana `success` + `properties->>'outcome'` (`success`/`empty_response`). WhatsApp nao tem `command_used`/`start_received` — usa briefing/cvm como features; o funil comeca em `whatsapp_offer_shown`.
- **Edge function**: 14º `fetchRpc` no `Promise.all` (`get_analytics_data_airton_whatsapp_v1`, apos `..._airton_telegram_v1`); merge `...(bhAirtonWa || {})` em `bhMerged` (apos `bhAirtonTg`).
- **Frontend** (`renderBhAirton`): blocos WhatsApp antes do Telegram — "Airton via WhatsApp" (7 KPIs + daily stacked `#25d366`/`#3ecf8e` + offers chart), "WhatsApp: funil de vinculacao" (funil de usuarios unicos + daily), "WhatsApp: features & outcomes" (2 tabelas). Card "% via WhatsApp" no hero e "Last source: whatsapp" nas threads. Estado de admin/periodo reutiliza o wiring existente (mensagens em airton_v2 respeitam o toggle; funil le de `usage_events_clean`).

## BH Engagement v2 — Admin Filter + Period Window (2026-05-03)

Reformulação das metricas de engajamento BH para corrigir 3 problemas: (1) `lifetime_feature_top_users` lia da tabela `lifetime_feature_usage` que era populada inconsistentemente pelo app (apenas 5 de 13 users de Macro Beta apareciam); (2) os 3 admins inflavam todas as KPIs (gabriel.dantas sozinho responde por ~85% dos eventos `macro_*`); (3) RPC original era all-time, ignorava `globalFilters.from/to`.

- **Nova view** `usage_events_clean` no projeto BH: clone de `usage_events` filtrado por `NOT EXISTS profiles WHERE is_admin=true`. Usada por todas as queries da v2.
  - **Migration 2026-05-12** (`20260512230000_remediate_security_views.sql`): substitui o `LEFT JOIN auth.users` original (que expunha `auth.users` ao linter `auth_users_exposed` e dependia de 3 emails hardcoded: lucasmello/lucastnm/gabriel.dantas) por filtro dinâmico via `profiles.is_admin`. View virou `WITH (security_invoker = true)` + `REVOKE ALL FROM PUBLIC, anon` + apenas `GRANT SELECT TO authenticated, service_role`. As 5 outras views (`v_brapi_dashboard`, `analyst_public_profiles`, `iacoes_sessions_enriched`, `iacoes_page_views_human`, `v_gemini_cost_per_user_30d`) também foram convertidas pra `security_invoker=true` na mesma migration.
  - **Mudança de métrica esperada**: o set de admins reais é **5** (gabriel.dantas, lucastnm, joao.lasmar, lgtcoliveira, bh-qa-diag) — lucasmello deixou de ser admin no `profiles`, joao/lgt/qa passaram a ser excluídos. Snapshot 7d ao aplicar (2026-05-12): `usage_events` raw = 10.424; `usage_events_clean` = 2.859; admin events excluídos = 7.565. **72,6% dos eventos vinham de admins** — KPIs do dashboard vão cair em relação à versão pré-fix, mas refletindo realidade. Não é regressão.
- **Nova RPC** `get_analytics_data_bh_extras_v2(p_from timestamptz, p_to timestamptz)` — substitui `get_analytics_data_bh_extras()` na Edge Function. Defaults: ultimos 30 dias. Differenças vs v1:
  - Lê de `usage_events_clean` (sem admins) em vez de `usage_events`.
  - Aplica `event_ts BETWEEN p_from AND p_to` em todos os blocos com dimensão temporal (KPIs, funnels, daily series). KPIs antes all-time agora respeitam o período.
  - `lifetime_feature_usage_summary` e `lifetime_feature_top_users` derivam de `usage_events_clean.feature` (column autoritativa) em vez da tabela `lifetime_feature_usage` quebrada.
  - `macro_beta_overview.unique_users` e `macro_beta_daily.unique_users`: lista explícita de event_names em vez de `LIKE 'macro_%'` (não captura mais eventos futuros não-Macro Beta).
  - **Dedup**: `cvm_filter_portfolio_apply` removido de `portfolio_activity_daily` (mantém só em `cvm_activity_daily`); `macro_beta_upgrade_click` removido de `paywall_v2_funnel.unique_clicked`.
  - Inclui campo `meta` no response: `{from, to, admins_excluded, source}`.
- **Edge function**: `analytics-dashboard/index.ts` agora aceita `?from=ISO&to=ISO`, default ultimos 30 dias, e passa `{p_from, p_to}` no body do `fetchRpc("get_analytics_data_bh_extras_v2")`. Helper `parseTimeWindow(req)` faz o parse. Response inclui `window: {from, to}`.
- **Frontend** (`index.html`): `fetchAnalytics()` envia `?from&to` baseado em `globalFilters`. Novo helper `refetchAndRerender()` (com guard `refetchInFlight`) é chamado em `applyPreset()` e nos listeners de `globalFrom`/`globalTo` — antes só re-renderizava client-side, agora refetcha do backend. `FEATURE_LABELS` atualizado para `{macro_beta, optimizer, portfolio_ianalise, portfolio_backtest, portfolio_macro_verdict, ...}` — keys agora batem com `feature` column.
- **v1 preservada**: `get_analytics_data_bh_extras()` continua existindo no DB para backward-compat. Edge Function não chama mais.
- **Não migrado nesta fase** (RPCs ainda all-time / sem admin filter): `get_analytics_data` (feature_usage, conversion_funnel, retention_cohorts, ticker_*, user_inactivity, etc.), `get_notification_analytics`, `get_analytics_data_bh_utm`, `get_analytics_data_bh_oauth`, `get_analytics_data_iacoes_daily`. Próxima fase.

## Google OAuth Adoption (2026-05-01)

Tracking de adocao do login via Google OAuth (habilitado em 2026-04-30, commits 27f19c7 + 690c9ae no projeto BH).

- **Eventos novos em `usage_events`** (gravados pelo client BH via `trackUsageEvent()`):
  - `event_name='auth_login'` com `action IN ('started','success','error')` e `properties->>'method' IN ('google','email')`
  - `event_name='profile_type_onboarding_complete'` com `action='success'`, `properties->>'method'` e `properties->>'profile_type'` (so dispara na 1a vez por user — proxy de novo signup OAuth)
  - Google OAuth NAO dispara `auth_signup_complete` (Supabase trata signup-via-OAuth como login normal). Pra contar "novos signups Google" use `oauth_first_login_daily` (1o `auth_login success` por user).
- **Nova RPC** `get_analytics_data_bh_oauth()` (additive — nao toca em `get_analytics_data` ou outras). Retorna 3 secoes daily:
  - `oauth_login_daily` — (day, method, action, cnt) — pivote no frontend pra: % Google share, success rate, funnel started→success/error, daily stacked
  - `oauth_first_login_daily` — (day, method, cnt) — proxy de novos signups por metodo
  - `oauth_profile_type_daily` — (day, method, profile_type, cnt) — segmentacao Google vs email por tipo de perfil
- **Edge function**: `analytics-dashboard/index.ts` adicionou um 9o `fetchRpc(BH_URL, BH_ANON, "get_analytics_data_bh_oauth")` no `Promise.all` e merge no `bhMerged`.
- **Frontend** (`index.html`, `renderBhAquisicao`): novo bloco "Metodos de Login (Google OAuth)" entre o funil de conversao e a secao UTM. Inclui 6 KPIs (% share, totais por metodo, success rate, errors), stacked daily Google vs Email, % Google share diario (linha), Google funnel (started/success/error), profile_type por metodo, novos signups diarios por metodo.

## Landing iAcoes — Daily Breakdowns (2026-04-30)

Visao Diaria + filtro temporal total na aba Landing iAcoes.

- **Nova RPC** `get_analytics_data_iacoes_daily()` (additive — nao toca em `get_analytics_data`). Retorna 8 secoes `_daily` que substituem snapshots all-time no frontend:
  - `iacoes_devices_daily`, `iacoes_browsers_daily`, `iacoes_os_daily`
  - `iacoes_utm_daily`
  - `iacoes_cta_breakdown_daily`, `iacoes_cta_by_page_daily`
  - `iacoes_source_detection_daily`
  - `iacoes_vs_other_conversion_daily` (valores absolutos `sessions/logins/paywall` — frontend recomputa taxas apos agregar)
- **Edge function**: `analytics-dashboard/index.ts` adicionou um 8º `fetchRpc(BH_URL, BH_ANON, "get_analytics_data_iacoes_daily")` no `Promise.all` e merge no `bhMerged` via spread.
- **Frontend** (`index.html`, `renderIacoesTab` em `:2970`): nova secao "Visao Diaria" no topo (6 mini-charts: Views, Sessoes Landing, CTA Clicks, Sessoes->BH, Logins, Pagamentos) + helper local `aggregateBy(rows, keyFields, sumFields)` que agrega as 8 series filtradas via `filterSnapshot`. Resultado: TODA visualizacao da aba respeita `globalFilters.from`/`to`.
- Snapshots originais (`iacoes_devices`, `iacoes_browsers`, `iacoes_os`, `iacoes_utm`, `iacoes_cta_breakdown`, `iacoes_cta_by_page`, `iacoes_source_detection`, `iacoes_vs_other_conversion`) permanecem na RPC `get_analytics_data` por compatibilidade — apenas nao sao mais consumidos pelo frontend.

## UTM Attribution (2026-04-27)

Captura e visualizacao de campanhas via parametros `utm_*` em `usage_events` (tabela do projeto BH).

- **Nova RPC** `get_analytics_data_bh_utm()` (additive — nao toca em `get_analytics_data` ou `get_analytics_data_bh_extras`). Retorna 7 secoes:
  - `usage_utm_summary` — top 30 source/medium/campaign nos ultimos 90d
  - `usage_utm_daily` — serie diaria por utm_source
  - `usage_utm_by_content` — top 50 criativos (utm_content) com sessions/logins/payments
  - `usage_utm_funnel_by_source` — conversao por fonte (sessao -> login -> paywall -> pagamento), session-level join
  - ~~`usage_utm_50off_*`~~ — as 3 secoes da campanha 50OFF foram **removidas em 2026-08-17** (campanha expirada; ver Overhaul acima)
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
- `report_downloads_daily` (~~`top_tickers_market`, `sector_distribution`~~ removidas em 2026-08-17 — market data de `brapi_quotes`, irrelevante)
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
- `token_usage_daily`: **LEGADO** (proxy_daily_usage parou em 07/abr/26). Frontend agora usa `server_token_daily`.
- `token_usage_summary`: **LEGADO** — frontend agora usa `server_token_summary`.
- `token_usage_by_user`: **LEGADO/HISTORICO** ate 07/abr/26 — server_token_usage nao tem user_id.
- `server_token_daily`: tokens por dia/source/model (de `server_token_usage`, com `is_backfill` flag)
- `server_token_summary`: agregados por source/model
- `server_token_last_24h`: tokens consumidos hoje (substitui `last_24h.{requests,prompt,completion}_tokens`)
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
- **Cross-project data**: A Edge Function usa service role key de **ambos** os projetos (HTA via `SUPABASE_SERVICE_ROLE_KEY`, BH via `BH_SERVICE_ROLE_KEY` ou `CVM_SERVICE_ROLE_KEY`). Anon do BH **nao funciona mais** — as RPCs analytics nao concedem EXECUTE a anon desde 2026-05-12. Se as keys mudarem, atualizar nos secrets do projeto HTA, nao no codigo.
- **RPC functions**: Criadas com `SECURITY DEFINER` e precisam de `GRANT EXECUTE` para anon/authenticated/service_role.
- **Token tracking server-side (estado real em 2026-05-03)**: A pipeline migrou de `proxy_daily_usage`+`increment_proxy_tokens` para a tabela `server_token_usage`+RPC `track_server_tokens(p_source, p_model_name, p_prompt_tokens, p_completion_tokens, p_thoughts_tokens, p_total_tokens)`. A nova tabela **nao tem `user_id`** — agregada por `(usage_date, source, model_name, is_backfill)`. Estado por proxy:
  - `gemini-proxy` v442: chama `track_server_tokens` ✅; **nao chama `check_proxy_rate_limit`** ❌ (rate limit ausente — gap de defesa em profundidade); nao chama `log_proxy_error` ❌
  - `anthropic-proxy` v408: chama `check_proxy_rate_limit` (50/dia, fail-closed) ✅; **nao persiste tokens** ❌ (tokens de Claude perdidos); nao chama `log_proxy_error` ❌
  - `gemini-market-proxy` v369: chama ambos `check_proxy_rate_limit` (100/dia, fail-open) ✅ e `track_server_tokens` ✅; nao chama `log_proxy_error` ❌
  - Frontend `isAiToken` filtra `(proxy_name||source) NOT IN ('brapi','partnr-news')` e `model_name != 'unknown'`.
- **`token_usage_*` keys (legacy)**: continuam expostos pela RPC mas lendo de `proxy_daily_usage` que esta abandonado desde 07/abr/26. Frontend nao consome mais (exceto `token_usage_by_user` para historico per-user).
- **Error metrics**: tabela `proxy_error_log` permanece com **0 rows** porque nenhum dos 3 proxies chama `log_proxy_error()`. A secao "Erros de API" mostra "Nenhum erro registrado" — nao por falta de erros, mas por falta de write-path. RPC `log_proxy_error()` existe e funciona; falta o caller.

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
  - **iAcoes** (8 sub-abas): Visao Geral, Aquisicao, Engajamento, Airton, Emails, Retencao, Receita & Assinaturas, Detalhes
  - **Horizon Terminal** (6 sub-abas): Visao Geral, Aquisicao, Engajamento, Retencao, Custos, Detalhes
  - **Landing iAcoes** (standalone — tracking do site `iacoes.brasilhorizonte.com.br`)
- **Top bar** (sticky): titulo da aba (`iAcoes - X` / `HTA - X`) + filtros globais + admin info
- **Area de conteudo**: fundo claro (#f5f7fa), cards brancos com sombra sutil
- **Regra**: dados iAcoes (BH) e HTA nunca combinados num mesmo grafico/tabela/KPI
- **Paywall consolidado (2026-06-22)** em `renderBhCustos`: paywall v1 + v2 unidos numa unica secao "Paywall & Conversao" (KPIs v2 reduzidos de 8→4 + daily stacked + funil + "Features que Levam ao Paywall" v1). A antiga Section 3 virou "Retencao & Churn" (sem o grafico de paywall e sem o KPI "Paywall→Checkout", movidos para a secao consolidada). Apenas frontend — chaves de backend (`paywall_v2_*`, `feature_paywall`) inalteradas.

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
