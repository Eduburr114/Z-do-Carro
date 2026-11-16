import 'server-only'
import type { Mailer } from '@/lib/email/outbox'

/**
 * Envio pela API do Resend (POST https://api.resend.com/emails), com o
 * cabeçalho Idempotency-Key (o mesmo que o SDK oficial envia): repetir o envio
 * com a mesma chave não gera um segundo e-mail.
 *
 * Classificação de erros: 429 e 5xx (e falha de rede) voltam para a fila com
 * espera crescente; demais 4xx (endereço inválido, domínio não verificado,
 * chave inválida) são definitivos e ficam registrados para a equipe.
 */
export function createResendMailer(options: { apiKey: string; from: string; replyTo?: string; baseUrl?: string; fetchImpl?: typeof fetch }): Mailer {
  const base = (options.baseUrl ?? 'https://api.resend.com').replace(/\/$/, '')
  const doFetch = options.fetchImpl ?? fetch
  return {
    async send(input) {
      let response: Response
      try {
        response = await doFetch(`${base}/emails`, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${options.apiKey}`,
            'Content-Type': 'application/json',
            'Idempotency-Key': input.idempotencyKey.slice(0, 256),
            'User-Agent': 'ze-do-carro-mailer/1.0',
          },
          body: JSON.stringify({
            from: options.from,
            to: [input.to],
            subject: input.subject,
            html: input.html,
            text: input.text,
            reply_to: options.replyTo ? [options.replyTo] : undefined,
            tags: input.tags,
          }),
          signal: AbortSignal.timeout(15_000),
        })
      } catch (error) {
        return { ok: false, retryable: true, error: `Sem resposta do Resend: ${error instanceof Error ? error.message : 'erro de rede'}` }
      }
      const data = (await response.json().catch(() => null)) as { id?: string; message?: string; name?: string } | null
      if (response.ok && data?.id) return { ok: true, id: data.id }
      const retryable = response.status === 429 || response.status >= 500
      return { ok: false, retryable, error: `Resend ${response.status}: ${data?.message ?? data?.name ?? 'erro'}` }
    },
  }
}
