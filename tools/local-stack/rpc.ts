/**
 * SOMENTE DESENVOLVIMENTO/TESTE LOCAL.
 * Executa uma função RPC do schema `public` do mesmo modo que a API de dados do
 * Supabase (PostgREST): dentro de uma transação, com o papel do banco e as
 * claims do JWT definidos para a requisição. Usado pelos testes de banco e pelo
 * emulador local.
 */
import type pg from 'pg'

export type DbRole = 'anon' | 'authenticated' | 'service_role'

export type Claims = {
  sub?: string
  role: DbRole
  aal?: 'aal1' | 'aal2'
  [key: string]: unknown
}

export class RpcError extends Error {
  code: string
  details: string | null
  hint: string | null
  constructor(error: { message: string; code?: string; detail?: string; hint?: string }) {
    super(error.message)
    this.name = 'RpcError'
    this.code = error.code ?? 'XX000'
    this.details = error.detail ?? null
    this.hint = error.hint ?? null
  }
}

type FunctionInfo = { argNames: string[]; argTypes: string[]; returnsVoid: boolean }
const functionCache = new Map<string, FunctionInfo | null>()

async function describeFunction(client: pg.ClientBase, name: string): Promise<FunctionInfo | null> {
  const cached = functionCache.get(name)
  if (cached !== undefined) return cached
  const { rows } = await client.query(
    `select coalesce(p.proargnames, '{}') as names,
            array(select format_type(t, null) from unnest(p.proargtypes::oid[]) as t) as types,
            p.prorettype = 'void'::regtype as returns_void
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = $1`,
    [name],
  )
  const info: FunctionInfo | null =
    rows.length === 1
      ? { argNames: rows[0].names, argTypes: rows[0].types, returnsVoid: rows[0].returns_void }
      : null
  functionCache.set(name, info)
  return info
}

export function clearFunctionCache(): void {
  functionCache.clear()
}

export async function withClaims<T>(
  client: pg.ClientBase,
  claims: Claims,
  run: () => Promise<T>,
): Promise<T> {
  await client.query('begin')
  try {
    await client.query(`set local role ${claims.role}`)
    await client.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify(claims)])
    const result = await run()
    await client.query('commit')
    return result
  } catch (error) {
    await client.query('rollback').catch(() => undefined)
    throw error
  }
}

export async function callRpc(
  client: pg.ClientBase,
  claims: Claims,
  name: string,
  args: Record<string, unknown> = {},
): Promise<unknown> {
  if (!/^[a-z_][a-z0-9_]*$/.test(name)) {
    throw new RpcError({ message: 'function not found', code: 'PGRST202' })
  }
  const info = await describeFunction(client, name)
  if (!info) throw new RpcError({ message: `Could not find the function public.${name}`, code: 'PGRST202' })

  const keys = Object.keys(args)
  const values: unknown[] = []
  const placeholders = keys.map((key, index) => {
    const position = info.argNames.indexOf(key)
    if (position === -1) {
      throw new RpcError({ message: `Could not find the function public.${name}(${keys.join(', ')})`, code: 'PGRST202' })
    }
    const type = info.argTypes[position]
    const value = args[key]
    values.push(
      (type === 'jsonb' || type === 'json') && value !== null && value !== undefined
        ? JSON.stringify(value)
        : value,
    )
    return `${key} => $${index + 1}::${type}`
  })

  try {
    return await withClaims(client, claims, async () => {
      const { rows } = await client.query(`select public.${name}(${placeholders.join(', ')}) as result`, values)
      return info.returnsVoid ? null : (rows[0]?.result ?? null)
    })
  } catch (error) {
    if (error instanceof RpcError) throw error
    const e = error as { message: string; code?: string; detail?: string; hint?: string }
    throw new RpcError(e)
  }
}
