import 'server-only'
import { GatewayError, toCents, type PixKeyType } from '@/lib/payments/asaas'
import { parseAsaasDate, syncPayment } from '@/lib/finance/charges'
import { processEvent } from '@/lib/finance/webhook'
import { sendPendingEmails } from '@/lib/email/outbox'
import type { FinanceDeps } from '@/lib/finance/types'

type Reconcile = { payment_id: string; external_id: string | null; attempt_key: string; status: string; remote_cancel: boolean; needs_qr: boolean }
type RefundJob = { refund_id: string; payment_id: string; external_id: string; amount_cents: number; reason: string }
type PayoutJob = { payout_id: string; claim_token: string; amount_cents: number; pix_key: string; pix_key_type: PixKeyType; description: string }
type PayoutCheck = { payout_id: string; claim_token: string | null; external_id: string | null; uncertain: boolean; claimed_at: string }

export type CycleSummary = Record<string, number | string | Record<string, number>>

const message = (error: unknown) => (error instanceof Error ? error.message : String(error))

/**
 * Uma rodada da rotina financeira. Cada etapa é independente: a falha de uma
 * não impede as outras, e tudo é idempotente (pode rodar em paralelo ou
 * repetir sem efeito duplicado).
 */
export async function runFinanceCycle(deps: FinanceDeps): Promise<CycleSummary> {
  const { rpc, gateway } = deps
  const summary: CycleSummary = {}
  const errors: string[] = []
  const step = async (name: string, fn: () => Promise<void>) => {
    try {
      await fn()
    } catch (error) {
      errors.push(`${name}: ${message(error)}`)
      deps.log?.(`[financeiro] etapa ${name} falhou`, { error: message(error) })
    }
  }

  await step('prazos', async () => {
    summary.tick = await rpc<Record<string, number>>('finance_tick')
  })

  if (gateway) {
    await step('cobrancas', async () => {
      const list = await rpc<Reconcile[]>('payments_to_reconcile', { p_limit: 50 })
      let synced = 0
      for (const item of list) {
        try {
          if (item.remote_cancel && item.external_id) {
            try {
              await gateway.deletePayment(item.external_id)
            } catch (error) {
              // Já paga ou já removida: o estado oficial decide.
              if (!(error instanceof GatewayError) || error.status === null || error.status >= 500) throw error
            }
            await rpc('payment_remote_cancelled', { p_payment_id: item.payment_id })
            await syncPayment(deps, item.external_id)
          } else if (item.status === 'creating') {
            // Criação interrompida: procura a cobrança pela referência da tentativa.
            const [found] = await gateway.findPaymentsByReference(item.attempt_key)
            if (found) {
              const qr = await gateway.getPixQrCode(found.id).catch(() => null)
              await rpc('payment_charge_created', {
                p_payment_id: item.payment_id, p_external_id: found.id, p_status: found.status,
                p_pix_payload: qr?.payload ?? null, p_pix_qr_image: qr?.encodedImage ?? null, p_pix_expires_at: parseAsaasDate(qr?.expirationDate),
              })
              await syncPayment(deps, found.id)
            } else {
              await rpc('payment_charge_failed', { p_payment_id: item.payment_id, p_error: 'Cobrança não encontrada no provedor' })
            }
          } else if (item.external_id) {
            if (item.needs_qr) {
              const qr = await gateway.getPixQrCode(item.external_id)
              await rpc('payment_charge_created', {
                p_payment_id: item.payment_id, p_external_id: item.external_id, p_status: 'PENDING',
                p_pix_payload: qr.payload, p_pix_qr_image: qr.encodedImage, p_pix_expires_at: parseAsaasDate(qr.expirationDate),
              })
            }
            await syncPayment(deps, item.external_id)
          }
          synced++
        } catch (error) {
          errors.push(`cobranca ${item.payment_id}: ${message(error)}`)
        }
      }
      summary.payments_checked = synced
    })

    await step('webhooks', async () => {
      const list = await rpc<{ id: number; event_type: string; resource_id: string | null }[]>('webhooks_to_retry', { p_limit: 50 })
      for (const event of list) {
        try {
          await rpc('webhook_done', { p_id: event.id, p_status: await processEvent(deps, event) })
        } catch (error) {
          await rpc('webhook_done', { p_id: event.id, p_status: 'failed', p_error: message(error) })
        }
      }
      summary.webhooks_retried = list.length
    })

    await step('estornos', async () => {
      const list = await rpc<RefundJob[]>('refund_claim', { p_limit: 20 })
      for (const job of list) {
        try {
          await gateway.refundPayment(job.external_id, `Estorno Zé do Carro (${job.reason})`)
          await rpc('refund_result', { p_refund_id: job.refund_id, p_ok: true })
          await syncPayment(deps, job.external_id)
        } catch (error) {
          const retryable = !(error instanceof GatewayError) || error.retryable || error.uncertain
          await rpc('refund_result', { p_refund_id: job.refund_id, p_ok: false, p_error: message(error), p_retryable: retryable })
        }
      }
      summary.refunds_sent = list.length
    })

    await step('repasses', async () => {
      const list = await rpc<PayoutJob[]>('payout_claim', { p_limit: 20 })
      for (const job of list) {
        try {
          const transfer = await gateway.createPixTransfer({
            valueCents: job.amount_cents, pixKey: job.pix_key, pixKeyType: job.pix_key_type,
            description: job.description, externalReference: job.payout_id,
          })
          await rpc('payout_transfer_created', {
            p_payout_id: job.payout_id, p_claim_token: job.claim_token, p_external_id: transfer.id, p_status: transfer.status,
            p_fee_cents: transfer.transferFee === undefined || transfer.transferFee === null ? null : toCents(transfer.transferFee),
          })
        } catch (error) {
          const gatewayError = error instanceof GatewayError ? error : null
          await rpc('payout_attempt_failed', {
            p_payout_id: job.payout_id, p_claim_token: job.claim_token, p_error: message(error),
            // Recusa definitiva do provedor também tenta de novo (saldo, instabilidade); o limite de tentativas encerra.
            p_retryable: true,
            p_uncertain: gatewayError ? gatewayError.uncertain : true,
          })
        }
      }
      summary.payouts_sent = list.length
    })

    await step('conciliacao_repasses', async () => {
      const list = await rpc<PayoutCheck[]>('payouts_to_reconcile', { p_limit: 50 })
      const now = (deps.now?.() ?? new Date()).getTime()
      for (const item of list) {
        try {
          if (item.external_id) {
            const transfer = await gateway.getTransfer(item.external_id)
            await rpc('payout_sync_transfer', {
              p_external_id: transfer.id, p_external_reference: transfer.externalReference ?? null, p_status: transfer.status,
              p_fail_reason: transfer.failReason ?? null,
              p_fee_cents: transfer.transferFee === undefined || transfer.transferFee === null ? null : toCents(transfer.transferFee),
            })
          } else if (item.uncertain && deps.transferValidationToken && now - new Date(item.claimed_at).getTime() > 30 * 60_000) {
            // Com a validação de saque ligada, toda transferência criada passa por
            // nós e fica vinculada ao repasse. Sem vínculo após 30 min, não saiu.
            await rpc('payout_attempt_failed', {
              p_payout_id: item.payout_id, p_claim_token: item.claim_token,
              p_error: 'Sem transferência vinculada após a validação de saque', p_retryable: true, p_uncertain: false,
            })
          }
        } catch (error) {
          errors.push(`repasse ${item.payout_id}: ${message(error)}`)
        }
      }
      summary.payouts_checked = list.length
    })
  } else {
    summary.gateway = 'não configurado'
  }

  await step('emails', async () => {
    summary.emails = await sendPendingEmails(deps)
  })

  summary.errors = errors.length
  if (errors.length) deps.log?.('[financeiro] rodada com erros', { errors })
  return summary
}
