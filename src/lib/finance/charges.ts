import 'server-only'
import { GatewayError, toCents, type AsaasPayment } from '@/lib/payments/asaas'
import type { ChargeToCreate, FinanceDeps } from '@/lib/finance/types'

/**
 * Datas do Asaas sem fuso ("2026-11-17 14:20:50") estão no horário de Brasília.
 * Devolve ISO 8601 ou nulo.
 */
export function parseAsaasDate(value: string | null | undefined): string | null {
  if (!value) return null
  const local = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}(:\d{2})?)$/.exec(value)
  const iso = local ? `${local[1]}T${local[2]}${local[3] ? '' : ':00'}-03:00` : value
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? null : date.toISOString()
}

export type ChargeResult = { ok: true } | { ok: false; message: string }

/**
 * Cria no provedor a cobrança Pix preparada por payment_start e registra o
 * resultado. A referência externa é a chave da tentativa: se a resposta se
 * perder, a conciliação encontra a cobrança por ela e nada é cobrado em dobro.
 */
export async function createCharge(deps: FinanceDeps, charge: ChargeToCreate): Promise<ChargeResult> {
  const { gateway, rpc } = deps
  if (!gateway) {
    await rpc('payment_charge_failed', { p_payment_id: charge.payment_id, p_error: 'Cobrança automática não configurada' })
    return { ok: false, message: 'O pagamento por Pix ainda não está disponível. Tente mais tarde.' }
  }
  let payment: AsaasPayment
  try {
    let customerId = charge.customer.external_id
    if (!customerId) {
      const created = await gateway.createCustomer({
        name: charge.customer.name, cpfCnpj: charge.customer.tax_id, email: charge.customer.email,
        mobilePhone: charge.customer.phone, externalReference: charge.customer.profile_id,
      })
      customerId = created.id
      await rpc('payment_customer_linked', { p_profile_id: charge.customer.profile_id, p_external_id: customerId })
    }
    payment = await gateway.createPixPayment({
      customer: customerId, valueCents: charge.amount_cents, dueDate: charge.due_date,
      description: charge.description, externalReference: charge.attempt_key,
    })
  } catch (error) {
    const gatewayError = error instanceof GatewayError ? error : null
    deps.log?.('[pagamento] falha ao criar cobrança', { status: gatewayError?.status, uncertain: gatewayError?.uncertain })
    // Incerto: fica "criando"; a conciliação procura pela referência externa.
    if (!gatewayError?.uncertain) {
      await rpc('payment_charge_failed', { p_payment_id: charge.payment_id, p_error: error instanceof Error ? error.message : 'erro' })
    }
    return { ok: false, message: 'Não foi possível gerar o Pix agora. Tente de novo em instantes.' }
  }
  if (toCents(payment.value) !== charge.amount_cents) {
    deps.log?.('[pagamento] valor da cobrança diferente do pedido', { payment: payment.id })
  }
  let qr: { payload: string | null; image: string | null; expires: string | null } = { payload: null, image: null, expires: null }
  try {
    const code = await gateway.getPixQrCode(payment.id)
    qr = { payload: code.payload, image: code.encodedImage, expires: parseAsaasDate(code.expirationDate) }
  } catch {
    // A cobrança existe; o QR Code é buscado de novo pela conciliação.
  }
  await rpc('payment_charge_created', {
    p_payment_id: charge.payment_id, p_external_id: payment.id, p_status: payment.status,
    p_pix_payload: qr.payload, p_pix_qr_image: qr.image, p_pix_expires_at: qr.expires,
  })
  return { ok: true }
}

/** Aplica no banco o estado oficial de uma cobrança, consultado na API. */
export async function syncPayment(deps: FinanceDeps, paymentId: string): Promise<string> {
  if (!deps.gateway) throw new Error('gateway_unavailable')
  const payment = await deps.gateway.getPayment(paymentId)
  const result = await deps.rpc<{ result: string }>('payment_sync', {
    p_external_id: payment.id,
    p_external_reference: payment.externalReference ?? null,
    p_status: payment.status,
    p_value_cents: toCents(payment.value),
    p_net_cents: payment.netValue === undefined || payment.netValue === null ? null : toCents(payment.netValue),
    p_deleted: Boolean(payment.deleted),
  })
  return result.result
}
