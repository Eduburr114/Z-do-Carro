'use server'

import { redirect } from 'next/navigation'
import { z } from 'zod'
import { formAction } from '@/lib/action'
import { createCharge } from '@/lib/finance/charges'
import { financeDeps } from '@/lib/finance/server'
import type { PaymentStart } from '@/lib/finance/types'
import { AppError } from '@/lib/rpc'
import { zCoord, zId } from '@/lib/zod'

export const saveVehicle = formAction(
  z.object({
    plate: z.string().trim().min(7, 'Informe a placa.').max(8),
    brand: z.string().trim().min(2, 'Informe a marca.').max(40),
    model: z.string().trim().min(1, 'Informe o modelo.').max(60),
    year: z.string().trim().regex(/^(19|20)\d{2}$/, 'Informe o ano com 4 dígitos.').transform(Number),
  }),
  async (input, { rpc }) => {
    await rpc('save_vehicle', { p_plate: input.plate, p_brand: input.brand, p_model: input.model, p_year: input.year })
  },
)

export const archiveVehicle = formAction(z.object({ id: zId }), async ({ id }, { rpc }) => {
  await rpc('archive_vehicle', { p_id: id })
})

export const createRequest = formAction(
  z.object({
    service_id: zId,
    vehicle_id: z.uuid('Escolha o veículo.'),
    address: z.string().trim().min(5, 'Informe onde o carro está.').max(240),
    notes: z.string().trim().max(500).optional(),
    lat: zCoord,
    lng: zCoord,
  }),
  async (input, { rpc }) => {
    const id = await rpc<string>('create_request', {
      p_service_id: input.service_id, p_vehicle_id: input.vehicle_id, p_address: input.address,
      p_lat: input.lat, p_lng: input.lng, p_notes: input.notes ?? '',
    })
    redirect(`/cliente/pedidos/${id}`)
  },
)

export const cancelRequest = formAction(z.object({ id: zId }), async ({ id }, { rpc }) => {
  await rpc('cancel_request', { p_id: id, p_reason: '' })
})

export const decideExtra = formAction(z.object({ id: zId, approve: z.enum(['yes', 'no']) }), async ({ id, approve }, { rpc }) => {
  await rpc('decide_extra', { p_extra_id: id, p_approve: approve === 'yes' })
})

/**
 * Gera (ou reaproveita) a cobrança Pix do pedido ou de um adicional. O banco
 * decide o valor; o servidor cria a cobrança no provedor com a chave secreta.
 * A confirmação do pagamento NUNCA vem daqui: só do webhook/consulta ao provedor.
 */
export const startPayment = formAction(z.object({ id: zId, extra_id: z.union([zId, z.literal('')]).optional() }), async ({ id, extra_id }, { rpc }) => {
  const start = await rpc<PaymentStart>('payment_start', { p_request_id: id, p_extra_id: extra_id || null })
  if (start.action === 'create') {
    const result = await createCharge(financeDeps(), start)
    if (!result.ok) throw new AppError('charge_failed', result.message)
  }
})

export const savePaymentTaxId = formAction(
  z.object({ tax_id: z.string().transform((v) => v.replace(/\D/g, '')).pipe(z.string().regex(/^(\d{11}|\d{14})$/, 'Informe o CPF (11 dígitos) ou CNPJ (14 dígitos).')) }),
  async ({ tax_id }, { rpc }) => {
    await rpc('save_payment_tax_id', { p_tax_id: tax_id })
  },
)

export const confirmCompletion = formAction(z.object({ id: zId }), async ({ id }, { rpc }) => {
  await rpc('confirm_completion', { p_id: id })
})

export const openDispute = formAction(
  z.object({ id: zId, reason: z.string().trim().min(20, 'Descreva o problema (ao menos 20 caracteres).').max(2000) }),
  async ({ id, reason }, { rpc }) => {
    await rpc('open_dispute', { p_id: id, p_reason: reason })
  },
)

export const claimPayment = formAction(z.object({ id: zId }), async ({ id }, { rpc }) => {
  await rpc('claim_payment', { p_id: id })
})

export const reviewRequest = formAction(
  z.object({
    id: zId,
    rating: z.enum(['1', '2', '3', '4', '5'], 'Escolha de 1 a 5 estrelas.').transform(Number),
    comment: z.string().trim().max(500).optional(),
  }),
  async ({ id, rating, comment }, { rpc }) => {
    await rpc('review_request', { p_id: id, p_rating: rating, p_comment: comment ?? '' })
  },
)
