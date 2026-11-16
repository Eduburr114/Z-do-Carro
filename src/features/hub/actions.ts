'use server'

import { z } from 'zod'
import { formAction } from '@/lib/action'
import { zId, zInt, zMoney } from '@/lib/zod'

export const decideProvider = formAction(
  z.object({
    id: zId,
    decision: z.enum(['approve', 'reject']),
    service_ids: z.array(zId).optional(),
    note: z.string().trim().max(1000).optional(),
  }).refine((v) => v.decision === 'reject' || (v.service_ids?.length ?? 0) > 0, { message: 'Marque ao menos um serviço para aprovar.' })
    .refine((v) => v.decision === 'approve' || (v.note?.length ?? 0) >= 10, { path: ['note'], message: 'Ao recusar, informe o motivo ao prestador.' }),
  async (input, { rpc }) => {
    await rpc('admin_decide_provider', {
      p_id: input.id, p_approved_service_ids: input.decision === 'approve' ? input.service_ids : [], p_note: input.note ?? '',
    })
  },
)

export const suspendProvider = formAction(
  z.object({
    id: zId,
    reason: z.string().trim().min(10, 'Descreva o motivo objetivo da suspensão.').max(1000),
    precautionary: z.literal('on').optional(),
  }),
  async ({ id, reason, precautionary }, { rpc }) => {
    await rpc('admin_suspend_provider', { p_id: id, p_reason: reason, p_precautionary: precautionary === 'on' })
  },
)

export const resolveSuspension = formAction(
  z.object({
    id: zId,
    decision: z.enum(['lift', 'uphold']),
    note: z.string().trim().min(10, 'Registre a fundamentação da decisão.').max(1000),
  }),
  async ({ id, decision, note }, { rpc }) => {
    await rpc('admin_resolve_suspension', { p_id: id, p_lift: decision === 'lift', p_note: note })
  },
)

export const markPayout = formAction(z.object({ id: zId }), async ({ id }, { rpc }) => {
  await rpc('admin_mark_payout', { p_request_id: id })
})

export const saveSettings = formAction(
  z.object({
    commission_percent: z.string().trim().transform((v) => v.replace(',', '.')).pipe(z.string().regex(/^\d{1,2}(\.\d{1,2})?$/, 'Informe a comissão, de 0 a 60.')).transform(Number),
    payout_days: zInt(0, 60, 'Informe de 0 a 60 dias.'),
    search_radius_km: zInt(1, 200, 'Informe de 1 a 200 km.'),
  }),
  async (input, { rpc }) => {
    await rpc('admin_save_settings', {
      p_commission_percent: input.commission_percent, p_payout_days: input.payout_days, p_search_radius_km: input.search_radius_km,
    })
  },
)

export const saveService = formAction(
  z.object({
    id: z.union([zId, z.literal('')]).optional(),
    name: z.string().trim().min(3, 'Informe o nome do serviço.').max(80),
    description: z.string().trim().max(300).optional(),
    base_price: zMoney,
    est_minutes: zInt(5, 600, 'Informe de 5 a 600 minutos.'),
    active: z.literal('on').optional(),
  }),
  async (input, { rpc }) => {
    await rpc('admin_save_service', {
      p_id: input.id || null, p_name: input.name, p_description: input.description ?? '', p_base_price: input.base_price,
      p_est_minutes: input.est_minutes, p_active: input.active === 'on',
    })
  },
)
