# Modelos de Dados

## Visao Geral

Dois projetos Supabase separados, cada um com sua propria RPC `get_analytics_data()` que retorna um JSON consolidado com todas as metricas.

## BH — brasilhorizonte (dawvgbopyemcayavcatd)

### Tabelas Principais

| Tabela | Descricao | Colunas-chave |
|--------|-----------|---------------|
| `usage_events` | Eventos de uso da plataforma | user_id, event_name, event_ts, ticker, feature, device_type, os, browser, session_id, referrer |
| `profiles` | Perfis de usuario + assinatura | user_id, created_at, subscription_status, plan, billing_period, is_special_client |
| `report_downloads` | Downloads de relatorios | user_id, report_id, created_at |
| `research_reports` | Relatorios publicados | id, title, company_id |
| `companies` | Empresas/tickers | id, ticker |
| `brapi_quotes` | Cotacoes de mercado | ticker, sector, regular_market_price, market_cap, dividend_yield, pl |
| `iacoes_page_views` | Tracking do site iAcoes | session_id, page_path, referrer, utm_source/medium/campaign, device_type, browser, os, event_type |

**Atencao:** `usage_events` usa `event_ts` (NAO `created_at`)

### RPC get_analytics_data() — BH

59 secoes retornadas incluindo:
- `overview`, `last_24h`, `daily_activity`, `usage_events_summary`
- `feature_usage`, `feature_usage_daily`, `conversion_funnel`
- `device_summary/daily`, `os_summary`, `browser_summary`
- `retention_cohorts`, `stickiness`, `new_vs_returning_daily`
- `subscribers_overview`, `subscribers_by_plan`, `signups_daily`
- `ticker_by_feature`, `ticker_trend_daily`, `feature_usage_trend`
- `ticker_ranking`, `user_ticker_usage`, `user_ticker_detail`
- `user_inactivity`, `inactivity_distribution`, `user_feature_breadth`
- `iacoes_*` (overview, daily, top_pages, referrers, referrer_daily, devices, browsers, os, utm)
- `iacoes_conversion_*` (funnel, daily, converting_tickers, vs_other_conversion)
- `session_metrics_daily`, `activity_heatmap`, `time_to_convert`
- `top_tickers_market`, `sector_distribution`, `table_sizes`
- `report_downloads_daily`, `top_reports_downloaded`
- `mrr_estimate`, `subscription_age`, `feature_paywall`
- `referrer_summary`, `referrer_detail`, `referrer_daily`

---

## HTA — Horizon Terminal Access (llqhmywodxzstjlrulcw)

### Tabelas Principais

| Tabela | Descricao | Colunas-chave |
|--------|-----------|---------------|
| `terminal_events` | Eventos do terminal | user_id, event_name, event_ts, created_at, feature, action, ticker, duration_ms, token_count, response_mode, device_type, os, browser, session_id |
| `chat_sessions` | Sessoes de chat | id, user_id, created_at |
| `chat_messages` | Mensagens de chat | session_id, created_at (SEM user_id — JOIN com chat_sessions) |
| `user_login_events` | Eventos de login | user_id, login_at (NAO login_events) |
| `proxy_daily_usage` | Uso diario de proxies | user_id, usage_date, proxy_name, model_name, request_count, input_tokens, output_tokens, total_prompt_tokens, total_completion_tokens, error_count |
| `proxy_error_log` | Log de erros de proxy | user_id, proxy_name, model_name, error_type, status_code, error_message, created_at |
| `server_token_usage` | Tokens server-side | usage_date, source, model_name, request_count, prompt_tokens, completion_tokens, thoughts_tokens, total_tokens |
| `user_profiles` | Perfis de usuario | status, client_type |
| `documents` | Documentos CVM (NAO cvm_documents) | doc_type |
| `user_watchlist` | Watchlist (NAO watchlist) | ticker |
| `user_daily_usage` | Uso diario legado | user_id, usage_date, question_count |

### RPC get_analytics_data() — HTA

44 secoes retornadas incluindo:
- `overview`, `last_24h`, `terminal_events_summary`
- `terminal_daily`, `chat_daily`, `daily_usage`
- `login_daily`, `top_tickers_searched`
- `token_usage_daily/summary/by_user`, `token_stats`, `token_by_mode`, `top_queries_by_token`
- `server_token_daily/summary/last_24h`
- `device_summary/daily`, `os_summary`, `browser_summary`
- `agent_success_daily`, `agent_duration_daily`
- `response_mode_summary/daily`, `chat_depth_distribution`
- `questions_daily`, `questions_by_user`
- `proxy_error_daily/summary/rate_daily`
- `ticker_by_feature`, `ticker_trend_daily`, `feature_usage_trend`
- `ticker_ranking`, `user_ticker_usage`, `user_ticker_detail`
- `user_inactivity`, `inactivity_distribution`, `user_feature_breadth`
- `watchlist`, `user_profiles_summary`, `documents_by_type`, `table_sizes`

---

## Funcoes RPC Auxiliares

| Funcao | Projeto | Descricao |
|--------|---------|-----------|
| `check_proxy_rate_limit(p_proxy_name, p_model_name, p_daily_limit)` | HTA | Rate limit 500/dia, conta request |
| `increment_proxy_tokens(p_proxy_name, p_prompt_tokens, p_completion_tokens, p_total_tokens, p_model_name)` | HTA | Persiste tokens apos API call |
| `log_proxy_error(p_user_id, p_proxy_name, p_model_name, p_error_type, p_status_code, p_error_message)` | HTA | Registra erros de proxy |

## Migrations

| Arquivo | Descricao |
|---------|-----------|
| `20260212_*_brasilhorizonte.sql` | RPC inicial BH |
| `20260212_*_horizon_terminal.sql` | RPC inicial HTA |
| `20260216_enhance_token_analytics.sql` | Token stats, mode breakdown |
| `20260226_add_error_metrics.sql` | proxy_error_log, error_count |
| `20260226_fix_token_tracking.sql` | Correcoes token tracking |
| `20260227_add_iacoes_referrer_tracking.sql` | Tracking iAcoes |
| `20260301_filter_non_ai_proxies.sql` | Filtro brapi/partnr-news |
| `20260401_dashboard_reformulation.sql` | Reformulacao sidebar + novas metricas |

Ultima atualizacao: 2026-04-01
