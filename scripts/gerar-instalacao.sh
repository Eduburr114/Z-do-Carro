#!/usr/bin/env bash
# Junta as migrações em supabase/instalar.sql, para colar de uma vez no editor
# SQL do Supabase em um projeto NOVO. Rode de novo sempre que mudar uma migração
# (um teste confere que o arquivo está em dia).
set -euo pipefail
cd "$(dirname "$0")/.."
{
  echo "-- GERADO por scripts/gerar-instalacao.sh a partir de supabase/migrations. Não edite à mão."
  echo "-- Instala o banco do Zé do Carro em um projeto Supabase novo e vazio."
  for file in supabase/migrations/*.sql; do
    printf '\n-- >>> %s\n' "$(basename "$file")"
    cat "$file"
    # Cada migração em uma transação própria (um valor novo de enum só pode ser
    # usado depois do COMMIT). Fora de transação, o COMMIT só gera um aviso.
    printf '\ncommit;\n'
  done
} > supabase/instalar.sql
