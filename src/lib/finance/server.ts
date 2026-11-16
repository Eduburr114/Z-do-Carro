import 'server-only'
import { after } from 'next/server'
import { createResendMailer } from '@/lib/email/resend'
import { sendPendingEmails } from '@/lib/email/outbox'
import { env } from '@/lib/env'
import { createAsaasClient } from '@/lib/payments/asaas'
import { createAdminClient } from '@/lib/supabase/admin'
import { ServiceRpcError, type FinanceDeps, type ServiceRpc } from '@/lib/finance/types'

/** Dependências reais dos fluxos financeiros, a partir das variáveis de ambiente. */
export function financeDeps(): FinanceDeps {
  const config = env()
  const admin = createAdminClient()
  const rpc: ServiceRpc = async (name, args = {}) => {
    const { data, error } = await admin.rpc(name, args)
    if (error) throw new ServiceRpcError(name, error.code ?? 'XX000', error.message)
    return data as never
  }
  return {
    rpc,
    gateway: config.ASAAS_API_KEY
      ? createAsaasClient({ apiKey: config.ASAAS_API_KEY, environment: config.ASAAS_ENV, baseUrl: config.ASAAS_BASE_URL })
      : null,
    webhookToken: config.ASAAS_WEBHOOK_TOKEN ?? null,
    transferValidationToken: config.ASAAS_TRANSFER_VALIDATION_TOKEN ?? null,
    mailer: config.RESEND_API_KEY && config.EMAIL_FROM
      ? createResendMailer({ apiKey: config.RESEND_API_KEY, from: config.EMAIL_FROM, replyTo: config.EMAIL_REPLY_TO, baseUrl: config.RESEND_BASE_URL })
      : null,
    appUrl: config.APP_URL ?? 'http://localhost:3000',
    log: (message, data) => console.warn(message, data ?? {}),
  }
}

/** Envia os e-mails que a ação acabou de enfileirar, depois da resposta. */
export function flushEmailsAfterResponse(): void {
  after(async () => {
    try {
      await sendPendingEmails(financeDeps(), 10)
    } catch (error) {
      console.error('[email] falha no envio', error instanceof Error ? error.message : error)
    }
  })
}
