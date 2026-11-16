'use server'

import { headers } from 'next/headers'
import { redirect } from 'next/navigation'
import { z } from 'zod'
import { formAction } from '@/lib/action'
import { rpc as callRpc } from '@/lib/rpc'
import { zCoord, zId, zInt, zMoney } from '@/lib/zod'

export const applyProvider = formAction(
  z.object({
    doc_type: z.enum(['cpf', 'cnpj']),
    doc_number: z.string().transform((v) => v.replace(/\D/g, '')).pipe(z.string().regex(/^(\d{11}|\d{14})$/, 'Confira o número do documento.')),
    legal_name: z.string().trim().min(3, 'Informe o nome ou a razão social.').max(160),
    city: z.string().trim().min(2, 'Informe a cidade.').max(80),
    experience: z.string().trim().max(1000).optional(),
    radius_km: zInt(1, 200, 'Informe um raio entre 1 e 200 km.'),
    service_ids: z.array(zId, 'Escolha ao menos um serviço.').min(1, 'Escolha ao menos um serviço.'),
    lat: zCoord,
    lng: zCoord,
  }),
  async (input, { rpc }) => {
    await rpc('provider_apply', {
      p_doc_type: input.doc_type, p_doc_number: input.doc_number, p_legal_name: input.legal_name, p_city: input.city,
      p_experience: input.experience ?? '', p_radius_km: input.radius_km, p_service_ids: input.service_ids,
      p_lat: input.lat, p_lng: input.lng,
    })
  },
)

/** Aceite eletrônico: o IP e o navegador são lidos aqui, no servidor (cláusula 15.1). */
export const acceptContract = formAction(
  z.object({ version_id: zId, agree: z.literal('on', 'Marque que leu e aceita o contrato.') }),
  async ({ version_id }, { rpc }) => {
    const h = await headers()
    const ip = h.get('x-forwarded-for')?.split(',')[0]?.trim() || h.get('x-real-ip') || 'desconhecido'
    await rpc('accept_contract', { p_version_id: version_id, p_ip: ip, p_user_agent: h.get('user-agent') ?? '' })
  },
)

export const setOnline = formAction(
  z.object({ online: z.enum(['yes', 'no']), lat: zCoord, lng: zCoord }),
  async ({ online, lat, lng }, { rpc }) => {
    await rpc('set_online', { p_online: online === 'yes', p_lat: lat, p_lng: lng })
  },
)

/** Posição durante a disponibilidade ou o atendimento. Falhas são ignoradas. */
export async function updatePosition(lat: number, lng: number): Promise<void> {
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) return
  await callRpc('update_position', { p_lat: lat, p_lng: lng }).catch(() => undefined)
}

export const acceptRequest = formAction(z.object({ id: zId }), async ({ id }, { rpc }) => {
  await rpc('accept_request', { p_id: id })
  // Redireciona no servidor: a lista de ofertas some assim que o pedido é aceito.
  redirect(`/prestador/pedidos/${id}`)
})

export const declineRequest = formAction(z.object({ id: zId }), async ({ id }, { rpc }) => {
  await rpc('decline_request', { p_id: id })
  redirect('/prestador')
})

export const advanceRequest = formAction(
  z.object({ id: zId, to: z.enum(['en_route', 'in_progress', 'completed']) }),
  async ({ id, to }, { rpc }) => {
    await rpc('advance_request', { p_id: id, p_to: to })
  },
)

export const withdrawRequest = formAction(
  z.object({ id: zId, reason: z.string().trim().min(10, 'Explique o motivo (ao menos 10 caracteres).').max(300) }),
  async ({ id, reason }, { rpc }) => {
    await rpc('withdraw_request', { p_id: id, p_reason: reason })
    redirect('/prestador')
  },
)

export const proposeExtra = formAction(
  z.object({ id: zId, description: z.string().trim().min(3, 'Descreva o serviço adicional.').max(200), price: zMoney }),
  async ({ id, description, price }, { rpc }) => {
    await rpc('propose_extra', { p_id: id, p_description: description, p_price: price })
  },
)

export const contestSuspension = formAction(
  z.object({ id: zId, text: z.string().trim().min(20, 'Explique a contestação (ao menos 20 caracteres).').max(2000) }),
  async ({ id, text }, { rpc }) => {
    await rpc('contest_suspension', { p_id: id, p_text: text })
  },
)

export const closeCredentialing = formAction(
  z.object({ confirm: z.literal('on', 'Marque a confirmação para encerrar.') }),
  async (_input, { rpc }) => {
    await rpc('close_credentialing')
  },
)
