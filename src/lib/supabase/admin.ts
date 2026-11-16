import 'server-only'
import { createClient } from '@supabase/supabase-js'
import { env } from '@/lib/env'

/**
 * Cliente com a chave secreta (papel service_role). Uso restrito ao servidor,
 * para o que não tem sessão de usuário: limite de tentativas, filas de push e
 * e-mail, webhooks e rotina financeira. As funções correspondentes no banco só
 * aceitam este papel. "server-only" faz o build falhar se for importado no
 * navegador.
 */
export function createAdminClient() {
  const config = env()
  return createClient(config.NEXT_PUBLIC_SUPABASE_URL, config.SUPABASE_SECRET_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
}
