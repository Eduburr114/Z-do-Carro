'use server'

import { z } from 'zod'
import { formAction } from '@/lib/action'
import { zId, zMoney } from '@/lib/zod'

/**
 * Ações da equipe financeira. Cada uma exige o papel 'finance' no banco, que
 * também registra a auditoria; aqui só se valida a entrada.
 */
const note = (min: number, message: string) => z.string().trim().min(min, message).max(1000)
const reference = z.string().trim().min(6, 'Informe o identificador (E2E ou comprovante).').max(120)

export const confirmManualPayment = formAction(z.object({ id: zId, reference }), async ({ id, reference }, { rpc }) => {
  await rpc('finance_confirm_manual_payment', { p_payment_id: id, p_reference: reference })
})

export const markRefundDone = formAction(z.object({ id: zId, reference }), async ({ id, reference }, { rpc }) => {
  await rpc('finance_mark_refund_done', { p_refund_id: id, p_reference: reference })
})

export const requestRefund = formAction(z.object({ id: zId, note: note(10, 'Registre o motivo do estorno.') }), async ({ id, note }, { rpc }) => {
  await rpc('finance_request_refund', { p_request_id: id, p_note: note })
})

export const retryRefund = formAction(z.object({ id: zId }), async ({ id }, { rpc }) => {
  await rpc('finance_retry_refund', { p_refund_id: id })
})

export const resolveDispute = formAction(
  z.object({ id: zId, outcome: z.enum(['provider', 'customer']), note: note(10, 'Registre a fundamentação da decisão.') }),
  async ({ id, outcome, note }, { rpc }) => {
    await rpc('finance_resolve_dispute', { p_dispute_id: id, p_outcome: outcome, p_note: note })
  },
)

export const holdPayout = formAction(z.object({ id: zId, reason: note(10, 'Registre o motivo da retenção.') }), async ({ id, reason }, { rpc }) => {
  await rpc('finance_hold_payout', { p_payout_id: id, p_reason: reason })
})

export const releasePayout = formAction(z.object({ id: zId }), async ({ id }, { rpc }) => {
  await rpc('finance_release_payout', { p_payout_id: id })
})

export const retryPayout = formAction(z.object({ id: zId }), async ({ id }, { rpc }) => {
  await rpc('finance_retry_payout', { p_payout_id: id })
})

export const resolveUncertainPayout = formAction(
  z.object({
    id: zId,
    sent: z.enum(['yes', 'no']),
    transfer_id: z.string().trim().max(100).optional(),
    note: note(10, 'Registre o que foi conferido no painel do provedor.'),
  }),
  async ({ id, sent, transfer_id, note }, { rpc }) => {
    await rpc('finance_resolve_uncertain_payout', { p_payout_id: id, p_sent: sent === 'yes', p_transfer_id: transfer_id ?? '', p_note: note })
  },
)

export const markPayoutPaid = formAction(z.object({ id: zId, reference }), async ({ id, reference }, { rpc }) => {
  await rpc('finance_mark_payout_paid', { p_payout_id: id, p_reference: reference })
})

export const reviewAccount = formAction(
  z.object({ id: zId, decision: z.enum(['approve', 'reject']), note: z.string().trim().max(500).optional() }),
  async ({ id, decision, note }, { rpc }) => {
    await rpc('finance_review_account', { p_account_id: id, p_approve: decision === 'approve', p_note: note ?? '' })
  },
)

export const authorizeWithdrawal = formAction(
  z.object({ amount: zMoney, pix_key: z.string().trim().min(3, 'Informe a chave Pix de destino.').max(140), note: note(5, 'Informe a finalidade do saque.') }),
  async ({ amount, pix_key, note }, { rpc }) => {
    await rpc('finance_authorize_withdrawal', { p_amount: amount, p_pix_key: pix_key, p_note: note })
  },
)
