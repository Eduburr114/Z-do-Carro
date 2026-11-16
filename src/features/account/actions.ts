'use server'

import { z } from 'zod'
import { formAction } from '@/lib/action'
import type { ActionState } from '@/lib/action-state'
import { getSession } from '@/lib/auth/session'
import { rpc as callRpc, AppError } from '@/lib/rpc'

export const updateProfile = formAction(
  z.object({
    full_name: z.string().trim().min(3, 'Informe o nome completo.').max(120),
    phone: z.string().transform((v) => v.replace(/\D/g, '')).pipe(z.string().regex(/^\d{10,11}$/, 'Informe o telefone com DDD.')),
  }),
  async ({ full_name, phone }, { rpc }) => {
    await rpc('update_profile', { p_full_name: full_name, p_phone: phone })
  },
)

const subscriptionSchema = z.object({
  endpoint: z.url().startsWith('https://').max(1000),
  keys: z.object({ p256dh: z.string().min(20).max(200), auth: z.string().min(10).max(100) }),
})

/** Guarda a inscrição de push deste aparelho para a conta atual. */
export async function savePushSubscription(subscription: unknown): Promise<ActionState> {
  if (!(await getSession())?.profile) return { ok: false, message: 'Sua sessão terminou. Entre de novo.' }
  const parsed = subscriptionSchema.safeParse(subscription)
  if (!parsed.success) return { ok: false, message: 'Não foi possível ativar os avisos neste aparelho.' }
  try {
    await callRpc('save_push_subscription', { p_endpoint: parsed.data.endpoint, p_p256dh: parsed.data.keys.p256dh, p_auth: parsed.data.keys.auth })
    return { ok: true }
  } catch (error) {
    return { ok: false, message: error instanceof AppError ? error.message : 'Não foi possível ativar os avisos.' }
  }
}

export async function deletePushSubscription(endpoint: string): Promise<void> {
  if (typeof endpoint !== 'string' || endpoint.length > 1000) return
  await callRpc('delete_push_subscription', { p_endpoint: endpoint }).catch(() => undefined)
}
