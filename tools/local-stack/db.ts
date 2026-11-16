/**
 * SOMENTE DESENVOLVIMENTO/TESTE LOCAL.
 * Cria (ou recria) um banco em um PostgreSQL comum e aplica: o "shim" que imita
 * o ambiente do Supabase e todas as migrações de supabase/migrations.
 * Nunca aponte isto para um banco de produção.
 */
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import pg from 'pg'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '..', '..')

export const ADMIN_URL =
  process.env.LOCAL_PG_ADMIN_URL ?? 'postgres://postgres:postgres@127.0.0.1:5432/postgres'

export function databaseUrl(name: string): string {
  const url = new URL(ADMIN_URL)
  url.pathname = `/${name}`
  return url.toString()
}

function assertLocal(): void {
  const host = new URL(ADMIN_URL).hostname
  if (!['127.0.0.1', 'localhost', '::1'].includes(host)) {
    throw new Error(`Recusado: ${host} não é um servidor local. Este utilitário apaga e recria o banco.`)
  }
}

export async function resetDatabase(name: string): Promise<string> {
  assertLocal()
  if (!/^[a-z_][a-z0-9_]*$/.test(name)) throw new Error('Nome de banco inválido')

  const admin = new pg.Client({ connectionString: ADMIN_URL })
  await admin.connect()
  try {
    await admin.query(
      'select pg_terminate_backend(pid) from pg_stat_activity where datname = $1 and pid <> pg_backend_pid()',
      [name],
    )
    await admin.query(`drop database if exists ${name}`)
    await admin.query(`create database ${name}`)
    await admin.query(`alter database ${name} set search_path = "$user", public, extensions`)
    await admin.query(`alter database ${name} set timezone = 'UTC'`)
  } finally {
    await admin.end()
  }

  const url = databaseUrl(name)
  const client = new pg.Client({ connectionString: url })
  await client.connect()
  try {
    await client.query(readFileSync(join(here, 'sql', '00_supabase_shim.sql'), 'utf8'))
    const dir = join(root, 'supabase', 'migrations')
    for (const file of readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()) {
      try {
        await client.query(readFileSync(join(dir, file), 'utf8'))
      } catch (error) {
        const e = error as Error & { position?: string; where?: string }
        throw new Error(`Falha na migração ${file}: ${e.message}${e.where ? `\n${e.where}` : ''}`, { cause: error })
      }
    }
  } finally {
    await client.end()
  }
  return url
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const name = process.argv[2] ?? 'zedocarro_local'
  resetDatabase(name)
    .then((url) => console.log(`Banco pronto: ${url.replace(/:[^:@/]+@/, ':***@')}`))
    .catch((error) => {
      console.error(error.message)
      process.exit(1)
    })
}
