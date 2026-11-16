import 'server-only'
import { createHash } from 'node:crypto'
import { headers } from 'next/headers'
import { createAdminClient } from '@/lib/supabase/admin'

export async function clientIp(): Promise<string> {
  const h = await headers()
  return h.get('x-forwarded-for')?.split(',')[0]?.trim() || h.get('x-real-ip') || 'desconhecido'
}

/** Endereço público do aplicativo, a partir da própria requisição. */
export async function appOrigin(): Promise<string> {
  const h = await headers()
  const host = h.get('x-forwarded-host') ?? h.get('host') ?? 'localhost:3000'
  const proto = h.get('x-forwarded-proto') ?? (host.startsWith('localhost') || host.startsWith('127.') ? 'http' : 'https')
  return `${proto}://${host}`
}

/** Chave anônima para o limite de tentativas: nem o IP nem o e-mail são gravados. */
export function limiterKey(...parts: string[]): string {
  return createHash('sha256').update(parts.join('|').toLowerCase()).digest('hex').slice(0, 32)
}

async function limit(key: string, max: number, windowSeconds: number, increment: boolean): Promise<boolean> {
  const { data, error } = await createAdminClient().rpc('check_rate_limit', { p_key: key, p_max: max, p_window_seconds: windowSeconds, p_increment: increment })
  if (error) {
    // Em falha do limitador, recusa: é melhor pedir para tentar de novo do que abrir a porta.
    console.error('[seguranca] limitador indisponível', error.code)
    return false
  }
  return data === true
}

/** Verdadeiro se ainda há tentativas disponíveis (não conta esta). */
export const underRateLimit = (key: string, max: number, windowSeconds: number) => limit(key, max, windowSeconds, false)
/** Conta a tentativa e diz se ela ainda cabe no limite. */
export const withinRateLimit = (key: string, max: number, windowSeconds: number) => limit(key, max, windowSeconds, true)

export async function registerFailure(key: string, max: number, windowSeconds: number): Promise<void> {
  await limit(key, max, windowSeconds, true)
}

export async function clearFailures(key: string): Promise<void> {
  await createAdminClient().rpc('clear_rate_limit', { p_key: key })
}
