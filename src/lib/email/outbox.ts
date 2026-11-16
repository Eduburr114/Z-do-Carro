import 'server-only'
import { renderEmail } from '@/lib/email/templates'
import type { ServiceRpc } from '@/lib/finance/types'

export type MailResult = { ok: true; id: string } | { ok: false; retryable: boolean; error: string }

/** Envio de um e-mail. A chave de idempotência evita duplicidade em novas tentativas. */
export type Mailer = {
  send(input: { to: string; subject: string; html: string; text: string; idempotencyKey: string; tags: { name: string; value: string }[] }): Promise<MailResult>
}

type Queued = { id: number; template: string; to_email: string | null; data: Record<string, unknown>; idempotency_key: string; attempts: number }

/**
 * Esvazia a fila de e-mails (notification_logs). Sem provedor configurado, o
 * e-mail é marcado como "não enviado" (skipped), nunca como enviado.
 */
export async function sendPendingEmails(deps: { rpc: ServiceRpc; mailer: Mailer | null; appUrl: string }, limit = 25): Promise<Record<string, number>> {
  const batch = await deps.rpc<Queued[]>('email_claim', { p_limit: limit })
  const counts = { sent: 0, retry: 0, failed: 0, skipped: 0 }
  for (const item of batch) {
    const content = renderEmail(item.template, item.data ?? {}, deps.appUrl)
    let outcome: keyof typeof counts
    let messageId: string | null = null
    let error: string | null = null
    if (!item.to_email) {
      outcome = 'failed'
      error = 'Sem destinatário'
    } else if (!content) {
      outcome = 'failed'
      error = `Modelo desconhecido: ${item.template}`
    } else if (!deps.mailer) {
      outcome = 'skipped'
      error = 'Envio de e-mail não configurado (RESEND_API_KEY)'
    } else {
      const result = await deps.mailer.send({
        to: item.to_email, ...content, idempotencyKey: item.idempotency_key,
        tags: [{ name: 'template', value: item.template }],
      })
      if (result.ok) {
        outcome = 'sent'
        messageId = result.id
      } else {
        outcome = result.retryable ? 'retry' : 'failed'
        error = result.error
      }
    }
    await deps.rpc('email_result', { p_id: item.id, p_outcome: outcome, p_message_id: messageId, p_error: error })
    counts[outcome]++
  }
  return counts
}
