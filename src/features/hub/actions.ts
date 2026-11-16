'use server'

import { z } from 'zod'
import { formAction } from '@/lib/action'
import { AppError } from '@/lib/rpc'
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

export const savePix = formAction(
  z.object({ pix_key: z.string().trim().max(140).optional(), pix_holder: z.string().trim().max(120).optional() }),
  async ({ pix_key, pix_holder }, { rpc }) => {
    await rpc('admin_save_pix', { p_pix_key: pix_key ?? '', p_pix_holder: pix_holder ?? '' })
  },
)

/** Gera o código de ativação para um novo acesso da equipe. Ele é mostrado uma única vez. */
export const newSetupCode = formAction(z.object({ role: z.enum(['admin', 'finance']).default('admin') }), async ({ role }, { rpc }) => {
  const code = await rpc<string>('admin_new_setup_code', { p_role: role })
  return { data: { code } }
})

/** Raio de busca. A comissão e o prazo são mantidos (mudam em "Regras financeiras"). */
export const saveSearchRadius = formAction(
  z.object({ search_radius_km: zInt(1, 200, 'Informe de 1 a 200 km.') }),
  async ({ search_radius_km }, { rpc }) => {
    const { settings } = await rpc<{ settings: { commission_percent: number; payout_days: number } }>('admin_overview')
    await rpc('admin_save_settings', { p_commission_percent: settings.commission_percent, p_payout_days: settings.payout_days, p_search_radius_km: search_radius_km })
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
    category_code: z.string().regex(/^[a-z_]{3,30}$/, 'Escolha a categoria.'),
  }),
  async (input, { rpc }) => {
    await rpc('admin_save_service', {
      p_id: input.id || null, p_name: input.name, p_description: input.description ?? '', p_base_price: input.base_price,
      p_est_minutes: input.est_minutes, p_active: input.active === 'on', p_category_code: input.category_code,
    })
  },
)

const zPercent = (max: number) => z.string().trim().transform((v) => v.replace(',', '.'))
  .pipe(z.string().regex(/^\d{1,2}(\.\d{1,2})?$/, `Informe de 0 a ${max}.`)).transform(Number).refine((v) => v <= max, `Informe de 0 a ${max}.`)
const zMoneyOrZero = z.string().trim().transform((v) => (v.includes(',') ? v.replace(/\./g, '').replace(',', '.') : v) || '0')
  .pipe(z.string().regex(/^\d{1,6}(\.\d{1,2})?$/, 'Informe um valor válido.')).transform(Number)
/** Data e hora do formulário (horário de Brasília, sem fuso) para ISO. */
const zLocalDateTime = z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/, 'Informe data e hora.').transform((v) => new Date(`${v}:00-03:00`).toISOString())
const zOptionalId = z.union([zId, z.literal('')]).optional().transform((v) => v || null)

export const saveFinanceSettings = formAction(
  z.object({
    commission_percent: zPercent(60),
    payout_days: zInt(0, 60, 'Informe de 0 a 60 dias.'),
    confirm_hours: zInt(1, 168, 'Informe de 1 a 168 horas.'),
    payment_window_minutes: zInt(10, 1440, 'Informe de 10 a 1440 minutos.'),
    platform_fee: zMoneyOrZero.refine((v) => v <= 100, 'Até R$ 100.'),
    min_charge_amount: zMoney,
    payment_provider: z.enum(['asaas', 'manual']),
    payout_mode: z.enum(['asaas', 'manual']),
    account_cooldown_hours: zInt(0, 168, 'Informe de 0 a 168 horas.'),
  }),
  async (input, { rpc }) => {
    await rpc('admin_save_finance_settings', {
      p_commission_percent: input.commission_percent, p_payout_days: input.payout_days, p_confirm_hours: input.confirm_hours,
      p_payment_window_minutes: input.payment_window_minutes, p_platform_fee: input.platform_fee, p_min_charge_amount: input.min_charge_amount,
      p_payment_provider: input.payment_provider, p_payout_mode: input.payout_mode, p_account_cooldown_hours: input.account_cooldown_hours,
    })
  },
)

export const saveCategory = formAction(
  z.object({
    code: z.string().regex(/^[a-z_]{3,30}$/, 'Use letras minúsculas e _ (3 a 30).'),
    name: z.string().trim().min(3, 'Informe o nome.').max(60),
    sort: zInt(0, 9999, 'Informe a ordem.'),
    active: z.literal('on').optional(),
  }),
  async (input, { rpc }) => {
    await rpc('admin_save_category', { p_code: input.code, p_name: input.name, p_sort: input.sort, p_active: input.active === 'on' })
  },
)

export const saveRegion = formAction(
  z.object({
    id: zOptionalId,
    code: z.string().regex(/^[a-z_]{3,40}$/, 'Use letras minúsculas e _ (3 a 40).'),
    name: z.string().trim().min(3, 'Informe o nome.').max(80),
    uf: z.string().trim().toUpperCase().regex(/^[A-Z]{2}$/, 'Informe a UF.'),
    lat: z.string().trim().transform((v) => Number(v.replace(',', '.'))).refine((v) => Number.isFinite(v) && v >= -90 && v <= 90, 'Latitude inválida.'),
    lng: z.string().trim().transform((v) => Number(v.replace(',', '.'))).refine((v) => Number.isFinite(v) && v >= -180 && v <= 180, 'Longitude inválida.'),
    radius_km: zInt(1, 300, 'Informe de 1 a 300 km.'),
    active: z.literal('on').optional(),
    is_default: z.literal('on').optional(),
  }),
  async (input, { rpc }) => {
    await rpc('admin_save_region', {
      p_id: input.id, p_code: input.code, p_name: input.name, p_uf: input.uf, p_lat: input.lat, p_lng: input.lng,
      p_radius_km: input.radius_km, p_active: input.active === 'on', p_default: input.is_default === 'on',
    })
  },
)

export const setRegionPrice = formAction(
  z.object({ service_id: zId, region_id: zId, price: z.string().trim() }),
  async ({ service_id, region_id, price }, { rpc }) => {
    const value = price === '' ? null : Number(price.includes(',') ? price.replace(/\./g, '').replace(',', '.') : price)
    if (value !== null && !(value > 0)) throw new AppError('invalid_price', 'Informe um preço válido ou deixe em branco para usar o de tabela.')
    await rpc('admin_set_region_price', { p_service_id: service_id, p_region_id: region_id, p_price: value })
  },
)

export const savePromotion = formAction(
  z.object({
    id: zOptionalId,
    name: z.string().trim().min(3, 'Informe o nome.').max(80),
    kind: z.enum(['percent', 'fixed']),
    value: zMoney,
    service_id: zOptionalId,
    category_code: z.string().optional().transform((v) => v || null),
    region_id: zOptionalId,
    starts_at: zLocalDateTime,
    ends_at: zLocalDateTime,
    max_redemptions: z.string().trim().optional().transform((v) => (v ? Number(v) : null)).refine((v) => v === null || (Number.isInteger(v) && v > 0), 'Informe um número inteiro.'),
    active: z.literal('on').optional(),
  }),
  async (input, { rpc }) => {
    await rpc('admin_save_promotion', {
      p_id: input.id, p_name: input.name, p_kind: input.kind, p_value: input.value, p_service_id: input.service_id,
      p_category_code: input.category_code, p_region_id: input.region_id, p_starts_at: input.starts_at, p_ends_at: input.ends_at,
      p_max_redemptions: input.max_redemptions, p_active: input.active === 'on',
    })
  },
)

export const createCommissionRule = formAction(
  z.object({
    name: z.string().trim().min(3, 'Dê um nome à regra.').max(80),
    scope: z.enum(['category', 'provider', 'campaign']),
    category_code: z.string().optional().transform((v) => v || null),
    provider_id: zOptionalId,
    percent: zPercent(60),
    starts_at: z.union([zLocalDateTime, z.literal('')]).optional().transform((v) => v || null),
    ends_at: z.union([zLocalDateTime, z.literal('')]).optional().transform((v) => v || null),
  }),
  async (input, { rpc }) => {
    await rpc('admin_create_commission_rule', {
      p_name: input.name, p_scope: input.scope, p_category_code: input.category_code, p_provider_id: input.provider_id,
      p_percent: input.percent, p_starts_at: input.starts_at, p_ends_at: input.ends_at,
    })
  },
)

export const endCommissionRule = formAction(z.object({ id: zId }), async ({ id }, { rpc }) => {
  await rpc('admin_end_commission_rule', { p_id: id })
})

export const setStaffRole = formAction(
  z.object({ user_id: zId, role: z.enum(['admin', 'finance']), grant: z.enum(['yes', 'no']) }),
  async ({ user_id, role, grant }, { rpc }) => {
    await rpc('admin_set_staff_role', { p_user_id: user_id, p_role: role, p_grant: grant === 'yes' })
  },
)
