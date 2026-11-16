import 'server-only'
import { createHash, timingSafeEqual } from 'node:crypto'
import { z } from 'zod'
import { toCents } from '@/lib/payments/asaas'
import { syncPayment } from '@/lib/finance/charges'
import type { FinanceDeps } from '@/lib/finance/types'

export const MAX_WEBHOOK_BYTES = 256 * 1024

/** Comparação em tempo constante (não revela, pelo tempo, quanto do token confere). */
export function tokenMatches(received: string | null | undefined, expected: string | null | undefined): boolean {
  if (!received || !expected) return false
  const a = createHash('sha256').update(received).digest()
  const b = createHash('sha256').update(expected).digest()
  return timingSafeEqual(a, b) && received.length === expected.length
}

const eventSchema = z.object({
  id: z.string().min(1).max(200),
  event: z.string().regex(/^[A-Z_]{3,80}$/),
  payment: z.object({ id: z.string().min(1).max(100) }).passthrough().optional(),
  transfer: z.object({ id: z.string().min(1).max(100) }).passthrough().optional(),
}).passthrough()

export type WebhookEvent = z.infer<typeof eventSchema>
type Reply = { status: number; body: Record<string, unknown> }

/**
 * Processa um evento a partir do recurso OFICIAL: o conteúdo do webhook só diz
 * "algo mudou em tal cobrança/transferência"; o estado vem da API do provedor.
 * Um webhook forjado com valores falsos, portanto, não confirma nada.
 */
export async function processEvent(deps: FinanceDeps, event: { event_type: string; resource_id: string | null }): Promise<'processed' | 'ignored'> {
  const type = event.event_type
  if (!event.resource_id) return 'ignored'
  if (type.startsWith('PAYMENT_')) {
    const result = await syncPayment(deps, event.resource_id)
    return result === 'unknown' ? 'ignored' : 'processed'
  }
  if (type.startsWith('TRANSFER_')) {
    if (!deps.gateway) throw new Error('gateway_unavailable')
    const transfer = await deps.gateway.getTransfer(event.resource_id)
    const result = await deps.rpc<{ result: string }>('payout_sync_transfer', {
      p_external_id: transfer.id,
      p_external_reference: transfer.externalReference ?? null,
      p_status: transfer.status,
      p_fail_reason: transfer.failReason ?? null,
      p_fee_cents: transfer.transferFee === undefined || transfer.transferFee === null ? null : toCents(transfer.transferFee),
    })
    return result.result === 'unknown' ? 'ignored' : 'processed'
  }
  return 'ignored'
}

/**
 * Webhook do Asaas. Ordem: autenticidade (token em tempo constante) →
 * formato → registro idempotente pelo id do evento → processamento. Responde
 * 200 assim que o evento está gravado; se o processamento falhar, a rotina
 * periódica tenta de novo (o Asaas pausa a fila de quem responde erro).
 */
export async function handleAsaasWebhook(deps: FinanceDeps, input: { token: string | null; rawBody: string; clientKey: string }): Promise<Reply> {
  if (!deps.webhookToken) return { status: 503, body: { error: 'webhook_not_configured' } }
  if (!tokenMatches(input.token, deps.webhookToken)) {
    // Limita tentativas com token errado por origem (sem gravar o IP em claro).
    const allowed = await deps.rpc<boolean>('check_rate_limit', { p_key: `wh:${input.clientKey}`, p_max: 20, p_window_seconds: 600, p_increment: true }).catch(() => false)
    deps.log?.('[webhook] token inválido', { limited: !allowed })
    return { status: allowed ? 401 : 429, body: { error: 'unauthorized' } }
  }
  if (Buffer.byteLength(input.rawBody, 'utf8') > MAX_WEBHOOK_BYTES) return { status: 413, body: { error: 'payload_too_large' } }
  let parsed: WebhookEvent
  try {
    const result = eventSchema.safeParse(JSON.parse(input.rawBody))
    if (!result.success) return { status: 400, body: { error: 'invalid_event' } }
    parsed = result.data
  } catch {
    return { status: 400, body: { error: 'invalid_json' } }
  }
  const resourceId = parsed.payment?.id ?? parsed.transfer?.id ?? null
  const record = await deps.rpc<{ id: number; duplicate: boolean }>('webhook_record', {
    p_provider: 'asaas', p_event_id: parsed.id, p_event_type: parsed.event, p_resource_id: resourceId, p_payload: parsed,
  })
  if (record.duplicate) return { status: 200, body: { received: true, duplicate: true } }
  try {
    const status = await processEvent(deps, { event_type: parsed.event, resource_id: resourceId })
    await deps.rpc('webhook_done', { p_id: record.id, p_status: status })
  } catch (error) {
    deps.log?.('[webhook] processamento adiado', { event: parsed.event, error: error instanceof Error ? error.message : String(error) })
    await deps.rpc('webhook_done', { p_id: record.id, p_status: 'failed', p_error: error instanceof Error ? error.message : 'erro' }).catch(() => undefined)
  }
  return { status: 200, body: { received: true } }
}

/**
 * Mecanismo de validação de saque do Asaas: antes de cada transferência sair,
 * o Asaas pergunta. Só aprova repasse conhecido, em processamento, com o mesmo
 * valor e a mesma chave (ou saque autorizado pela equipe). Em qualquer erro,
 * recusa: o pior caso é uma transferência a refazer, nunca uma indevida.
 */
export async function handleTransferValidation(deps: FinanceDeps, input: { token: string | null; rawBody: string }): Promise<Reply> {
  if (!deps.transferValidationToken) return { status: 503, body: { error: 'validation_not_configured' } }
  if (!tokenMatches(input.token, deps.transferValidationToken)) return { status: 401, body: { error: 'unauthorized' } }
  const refuse = (reason: string): Reply => ({ status: 200, body: { status: 'REFUSED', refuseReason: reason } })
  if (Buffer.byteLength(input.rawBody, 'utf8') > MAX_WEBHOOK_BYTES) return refuse('Requisição grande demais')
  try {
    const body = JSON.parse(input.rawBody) as Record<string, unknown>
    // Formato do Asaas: { type, transfer: {...} }. Campos desconhecidos são ignorados.
    const transfer = (body.transfer ?? body) as Record<string, unknown>
    const id = typeof transfer.id === 'string' ? transfer.id : null
    const value = typeof transfer.value === 'number' || typeof transfer.value === 'string' ? toCents(transfer.value as number) : null
    if (!id || value === null || value <= 0) return refuse('Transferência sem identificação ou valor')
    const bank = (transfer.bankAccount ?? {}) as Record<string, unknown>
    const pixKey = (typeof transfer.pixAddressKey === 'string' && transfer.pixAddressKey) || (typeof bank.pixAddressKey === 'string' && bank.pixAddressKey) || null
    const decision = await deps.rpc<{ approved: boolean; reason?: string }>('payout_validate_transfer', {
      p_transfer_id: id, p_value_cents: value,
      p_external_reference: typeof transfer.externalReference === 'string' ? transfer.externalReference : null,
      p_pix_key: pixKey,
    })
    return decision.approved ? { status: 200, body: { status: 'APPROVED' } } : refuse(decision.reason ?? 'Transferência não reconhecida')
  } catch (error) {
    deps.log?.('[saque] validação falhou; recusado por segurança', { error: error instanceof Error ? error.message : String(error) })
    return refuse('Não foi possível validar a transferência')
  }
}
