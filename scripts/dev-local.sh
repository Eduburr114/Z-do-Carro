#!/usr/bin/env bash
# SOMENTE DESENVOLVIMENTO LOCAL, sem Docker: recria o banco local com contas
# fictícias, sobe o emulador do Supabase e o Next.js. Requer PostgreSQL 16
# local (LOCAL_PG_ADMIN_URL, padrão postgres://postgres:postgres@127.0.0.1:5432).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env.local ] || cp tools/local-stack/env.local.example .env.local
pnpm -s local:db
pnpm -s local:api &
API_PID=$!
trap 'kill $API_PID 2>/dev/null || true' EXIT
pnpm -s dev
