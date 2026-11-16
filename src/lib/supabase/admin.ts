import 'server-only'
import { createClient } from '@supabase/supabase-js'
import { env } from '@/lib/env'

/**
 * Cliente com a chave secreta. Uso restrito a duas tarefas que não têm outro
 * caminho: o limite de tentativas (antes do login) e a fila de push. As funções
 * correspondentes no banco só aceitam este papel. Nunca importe em código de
 * cliente; "server-only" faz o build falhar se isso acontecer.
 */
export function createAdminClient() {
  const config = env()
  return createClient(config.NEXT_PUBLIC_SUPABASE_URL, config.SUPABASE_SECRET_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
}
