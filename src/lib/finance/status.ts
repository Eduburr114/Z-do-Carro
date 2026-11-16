import 'server-only'
import { env } from '@/lib/env'

/** O que está configurado no servidor (sem revelar valores). */
export function paymentsReady() {
  const config = env()
  return {
    asaas: Boolean(config.ASAAS_API_KEY),
    asaasEnv: config.ASAAS_ENV,
    webhook: Boolean(config.ASAAS_WEBHOOK_TOKEN),
    transferValidation: Boolean(config.ASAAS_TRANSFER_VALIDATION_TOKEN),
    cron: Boolean(config.CRON_SECRET),
    email: Boolean(config.RESEND_API_KEY && config.EMAIL_FROM),
  }
}
