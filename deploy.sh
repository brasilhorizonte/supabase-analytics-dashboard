#!/bin/bash
# Deploy do Dashboard Analytics para Supabase Storage
# Uso: ./deploy.sh

set -e

# Configuracoes
PROJECT_URL="https://llqhmywodxzstjlrulcw.supabase.co"
UPLOAD_ENDPOINT="${PROJECT_URL}/functions/v1/dashboard-upload"

# Pedir a service role key
echo "=== Deploy do Analytics Dashboard ==="
echo ""
echo "Voce precisa da Service Role Key do projeto Horizon Terminal Access."
echo "Encontre em: https://supabase.com/dashboard/project/llqhmywodxzstjlrulcw/settings/api"
echo ""
read -sp "Service Role Key: " SERVICE_KEY
echo ""
echo ""

# Verificar se index.html existe
if [ ! -f "index.html" ]; then
    echo "ERRO: arquivo index.html nao encontrado!"
    echo "Execute este script na raiz do projeto (onde esta o index.html)"
    exit 1
fi

echo "Fazendo upload do dashboard ($(wc -c < index.html | tr -d ' ') bytes)..."

# Upload via Edge Function
RESPONSE=$(curl -s -X POST "$UPLOAD_ENDPOINT" \
    -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: text/html" \
    --data-binary @index.html)

# Verificar resultado
if echo "$RESPONSE" | grep -q '"success":true'; then
    URL=$(echo "$RESPONSE" | grep -o '"url":"[^"]*"' | sed 's/"url":"//;s/"$//')
    echo ""
    echo "Deploy concluido com sucesso!"
    echo ""
    echo "Dashboard URL: $URL"
    echo ""
    echo "Acesse no navegador e faca login com suas credenciais de admin."
else
    echo ""
    echo "ERRO no deploy:"
    echo "$RESPONSE"
    exit 1
fi
