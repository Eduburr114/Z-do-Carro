import 'server-only'
import { createClient } from '@/lib/supabase/server'

/** Erro com mensagem pronta para o usuário. */
export class AppError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message)
    this.name = 'AppError'
  }
}

const fallbackMessages: Record<string, string> = {
  permission_denied: 'Você não tem permissão para esta ação.',
  immutable_record: 'Este registro não pode ser alterado.',
  period_closed: 'O período está encerrado. Use o fluxo de ajuste.',
}

type PostgrestLikeError = { code?: string; message: string; details?: string | null }

/**
 * Converte um erro do banco em mensagem para o usuário. As funções do banco
 * devolvem um código estável em `message` e o texto em português em `details`.
 * Erros inesperados nunca expõem detalhes internos.
 */
export function toAppError(error: PostgrestLikeError): AppError {
  const code = error.message
  if (code === 'permission_denied' || error.code === '42501') {
    return new AppError('permission_denied', fallbackMessages.permission_denied)
  }
  if (error.code === 'P0001' && /^[a-z_]+$/.test(code)) {
    return new AppError(code, error.details || fallbackMessages[code] || 'Não foi possível concluir a operação.')
  }
  if (error.code === '22P02' || error.code === '22007' || error.code === '22008' || error.code === '23514' || error.code === '23502') {
    return new AppError('invalid_input', 'Algum dado informado é inválido. Confira os campos e tente de novo.')
  }
  console.error('[rpc] erro inesperado', { code: error.code, message: error.message })
  return new AppError('unexpected', 'Ocorreu um erro inesperado. Tente de novo; se persistir, avise o responsável pelo sistema.')
}

/** Chama uma função RPC com a sessão do usuário. Lança AppError em caso de falha. */
export async function rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  const supabase = await createClient()
  const { data, error } = await supabase.rpc(name, args)
  if (error) throw toAppError(error)
  return data as T
}
