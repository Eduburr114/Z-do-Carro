import 'server-only'
import { cache } from 'react'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import type { ProviderStatus, Role } from '@/lib/types'

export type Session = {
  userId: string
  email: string | null
  profile: { id: string; full_name: string; phone: string; role: Role } | null
  provider: { status: ProviderStatus; online: boolean; contract_ok: boolean } | null
}

/**
 * Sessão da requisição atual. A identidade vem do JWT verificado (getClaims) e
 * o papel vem do banco (my_access), nunca de dados enviados pelo navegador.
 */
export const getSession = cache(async (): Promise<Session | null> => {
  const supabase = await createClient()
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims()
  if (claimsError || !claimsData?.claims?.sub) return null
  const { data, error } = await supabase.rpc('my_access')
  if (error || !data) return null
  const access = data as { user_id: string; profile: Session['profile']; provider: Session['provider'] }
  return {
    userId: access.user_id,
    email: (claimsData.claims.email as string | undefined) ?? null,
    profile: access.profile,
    provider: access.provider,
  }
})

export type ActiveSession = Session & { profile: NonNullable<Session['profile']> }

export const homeFor: Record<Role, string> = { customer: '/cliente', provider: '/prestador', hub_admin: '/hub' }

/** Exige usuário autenticado e com cadastro; redireciona para a etapa que falta. */
export async function requireUser(): Promise<ActiveSession> {
  const session = await getSession()
  if (!session) redirect('/login')
  if (!session.profile) redirect('/completar')
  return session as ActiveSession
}

/** Exige o papel para abrir a página; quem tem outro papel volta para a própria área. */
export async function requireRole(role: Role): Promise<ActiveSession> {
  const session = await requireUser()
  if (session.profile.role !== role) redirect(homeFor[session.profile.role])
  return session
}
