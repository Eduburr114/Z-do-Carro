'use server'

import { redirect } from 'next/navigation'
import { z } from 'zod'
import { formAction } from '@/lib/action'
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

export const payRequest = formAction(z.object({ id: zId }), async ({ id }, { rpc }) => {
  await rpc('pay_request', { p_id: id })
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
