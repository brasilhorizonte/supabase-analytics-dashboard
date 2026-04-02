# Contratos de API

## Edge Function: analytics-dashboard

**URL Base:** `https://llqhmywodxzstjlrulcw.supabase.co/functions/v1/analytics-dashboard`

### Autenticacao

| Header | Valor | Descricao |
|--------|-------|-----------|
| `Authorization` | `Bearer {access_token}` | JWT do Supabase Auth (projeto HTA) |

O token e obtido via login:
```
POST https://llqhmywodxzstjlrulcw.supabase.co/auth/v1/token?grant_type=password
Content-Type: application/json
apikey: {SUPABASE_ANON_KEY}

{ "email": "...", "password": "..." }
```

### Verificacao de Admin

Apos validar o JWT, a Edge Function consulta:
```sql
SELECT role FROM user_roles WHERE user_id = {uid} AND role = 'admin'
```
Usando a service role key. Se nao for admin, retorna 403.

### Endpoints

#### GET /functions/v1/analytics-dashboard

**Descricao:** Retorna todas as metricas de analytics de ambos os projetos.

**Autenticacao:** Bearer token (JWT) + role admin

**CORS:** Habilitado para todas as origens

**Response 200:**
```json
{
  "admin": "email@example.com",
  "bh": {
    "overview": { "total_users": 0, "active_sessions": 0, "storage_objects": 0, "db_size_bytes": 0 },
    "last_24h": { "events": 0, "dau": 0, "signups": 0, "logins": 0, ... },
    "daily_activity": [{ "day": "2026-01-01", "events": 0, "dau": 0 }],
    "ticker_ranking": [{ "ticker": "VALE3", "cnt": 100 }],
    "user_ticker_usage": [{ "email": "...", "total_queries": 0, "unique_tickers": 0, "top_ticker": "...", "top_feature": "...", "last_activity": "..." }],
    ...
  },
  "hta": {
    "overview": { "total_users": 0, "active_sessions": 0, "storage_objects": 0, "db_size_bytes": 0 },
    "last_24h": { "sessions": 0, "tasks": 0, "chat_msgs": 0, "logins": 0, "unique_users": 0, "requests": 0, "input_tokens": 0, "output_tokens": 0 },
    "terminal_daily": [{ "day": "2026-01-01", "sessions": 0, "tasks": 0, "chat_msgs": 0 }],
    "ticker_ranking": [{ "ticker": "VALE3", "cnt": 100 }],
    ...
  },
  "ts": "2026-04-01T12:00:00.000Z"
}
```

**Response 401:** Token ausente ou invalido
```json
{ "error": "Missing or invalid token" }
```

**Response 403:** Usuario nao e admin
```json
{ "error": "Forbidden: admin role required" }
```

**Response 500:** Erro interno
```json
{ "error": "Internal server error", "details": "..." }
```

#### OPTIONS /functions/v1/analytics-dashboard

**Descricao:** CORS preflight

**Response 200:** Headers CORS

---

## Edge Functions de Proxy (nao neste repo)

Deployadas separadamente no projeto HTA:

| Function | verify_jwt | Descricao |
|----------|-----------|-----------|
| `gemini-proxy` | false | Google Gemini API (tracking server-side) |
| `anthropic-proxy` | false | Anthropic Claude API |
| `gemini-market-proxy` | false | Gemini + BRAPI (mercado) |
| `openai-proxy` | true | OpenAI API |
| `brapi-proxy` | false | brapi.dev (cotacoes) |
| `partnr-news-proxy` | false | Partnr News API |

### Tracking Server-Side (gemini-proxy v256+)

1. **Antes da API call:** `check_proxy_rate_limit(proxy_name, model_name, 500)` — conta request + rate limit
2. **Apos a API call:** `increment_proxy_tokens(proxy_name, prompt, completion, total, model_name)` — persiste tokens
3. **Em caso de erro:** `log_proxy_error(user_id, proxy_name, model_name, error_type, status_code, message)`

Ultima atualizacao: 2026-04-01
