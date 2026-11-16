import 'server-only'
import { revalidatePath } from 'next/cache'
import type { z } from 'zod'
import { getSession, type Session } from '@/lib/auth/session'
import { flushEmailsAfterResponse } from '@/lib/finance/server'
import { flushPushesAfterResponse } from '@/lib/push'
import { AppError, rpc } from '@/lib/rpc'
import type { ActionState } from '@/lib/action-state'

type Handler<T> = (input: T, context: { session: Session; rpc: typeof rpc }) => Promise<Partial<ActionState> | void>

function formToObject(formData: FormData): Record<string, unknown> {
  const result: Record<string, unknown> = {}
  for (const [key, value] of formData.entries()) {
    if (key.startsWith('$ACTION')) continue
    if (typeof value !== 'string') continue
    if (key.endsWith('[]')) {
      const name = key.slice(0, -2)
      result[name] = [...((result[name] as string[] | undefined) ?? []), value]
    } else {
      result[key] = value
    }
  }
  return result
}

/**
 * Monta uma Server Action de formulário. Em toda chamada: confere a sessão no
 * servidor, valida a entrada com Zod e só então executa. A autorização final é
 * sempre do banco (as funções conferem o papel de novo).
 */
export function formAction<S extends z.ZodType>(schema: S, handler: Handler<z.output<S>>) {
  return async (_previous: ActionState, formData: FormData): Promise<ActionState> => {
    const session = await getSession()
    if (!session) return { ok: false, message: 'Sua sessão terminou. Entre de novo.', at: Date.now() }
    const parsed = schema.safeParse(formToObject(formData))
    if (!parsed.success) {
      const fieldErrors: Record<string, string> = {}
      for (const issue of parsed.error.issues) {
        const key = issue.path.join('.') || '_'
        if (!fieldErrors[key]) fieldErrors[key] = issue.message
      }
      return { ok: false, message: fieldErrors._ ?? 'Confira os campos destacados.', fieldErrors, at: Date.now() }
    }
    try {
      let result: Partial<ActionState> | void
      try {
        result = await handler(parsed.data, { session, rpc })
      } finally {
        // Também quando o handler termina em redirect(): a tela de destino precisa de dados novos.
        revalidatePath('/', 'layout')
        // Os avisos e e-mails gerados no banco por esta ação saem logo depois da resposta.
        flushPushesAfterResponse()
        flushEmailsAfterResponse()
      }
      return { ok: true, at: Date.now(), ...result }
    } catch (error) {
      if (error instanceof AppError) return { ok: false, message: error.message, at: Date.now() }
      // Erros de navegação do Next (redirect/notFound) precisam seguir adiante.
      if (error && typeof error === 'object' && 'digest' in error) throw error
      console.error('[action] erro inesperado', error)
      return { ok: false, message: 'Ocorreu um erro inesperado. Tente de novo.', at: Date.now() }
    }
  }
}
