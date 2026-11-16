'use server'

import { redirect } from 'next/navigation'
import { z } from 'zod'
import type { ActionState } from '@/lib/action-state'
import { toAppError } from '@/lib/rpc'
import { createClient } from '@/lib/supabase/server'

const fail = (message: string, fieldErrors?: Record<string, string>): ActionState => ({ ok: false, message, fieldErrors, at: Date.now() })

function fieldErrorsOf(error: z.ZodError): Record<string, string> {
  const fieldErrors: Record<string, string> = {}
  for (const issue of error.issues) fieldErrors[String(issue.path[0])] ??= issue.message
  return fieldErrors
}

const signInSchema = z.object({
  email: z.email().max(160),
  password: z.string().min(1).max(128),
})

export async function signIn(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = signInSchema.safeParse({ email: formData.get('email'), password: formData.get('password') })
  if (!parsed.success) return fail('Informe e-mail e senha.')
  const supabase = await createClient()
  const { error } = await supabase.auth.signInWithPassword(parsed.data)
  // Mesma mensagem para e-mail inexistente e senha errada.
  if (error) return fail('E-mail ou senha incorretos.')
  redirect('/')
}

export async function signOut(): Promise<void> {
  const supabase = await createClient()
  await supabase.auth.signOut({ scope: 'local' })
  redirect('/')
}

const profileSchema = z.object({
  full_name: z.string().trim().min(3, 'Informe o nome completo.').max(120),
  phone: z.string().transform((v) => v.replace(/\D/g, '')).pipe(z.string().regex(/^\d{10,11}$/, 'Informe o telefone com DDD.')),
  role: z.enum(['customer', 'provider'], 'Escolha como você vai usar o aplicativo.'),
})

const signUpSchema = profileSchema.extend({
  email: z.email('Informe um e-mail válido.').max(160),
  password: z.string().min(8, 'Use ao menos 8 caracteres.').max(128),
  terms: z.literal('on', 'É preciso concordar para criar a conta.'),
})

export async function signUp(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = signUpSchema.safeParse(Object.fromEntries(formData))
  if (!parsed.success) return fail('Confira os campos destacados.', fieldErrorsOf(parsed.error))
  const { email, password, full_name, phone, role } = parsed.data
  const supabase = await createClient()
  const { data, error } = await supabase.auth.signUp({ email, password })
  if (error) {
    if (error.code === 'user_already_exists') return fail('Confira os campos destacados.', { email: 'Já existe uma conta com este e-mail. Entre nela.' })
    if (error.code === 'weak_password') return fail('Confira os campos destacados.', { password: 'Escolha uma senha mais forte.' })
    return fail('Não foi possível criar a conta agora. Tente de novo em instantes.')
  }
  // Com confirmação de e-mail ligada no Supabase, a sessão só existe após o clique no link.
  if (!data.session) return { ok: true, message: 'confirm_email', at: Date.now() }
  const registered = await supabase.rpc('register_profile', { p_full_name: full_name, p_phone: phone, p_role: role })
  if (registered.error) return fail(toAppError(registered.error).message)
  redirect('/')
}

/** Quem confirmou o e-mail e ainda não tem cadastro termina por aqui. */
export async function completeProfile(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = profileSchema.safeParse(Object.fromEntries(formData))
  if (!parsed.success) return fail('Confira os campos destacados.', fieldErrorsOf(parsed.error))
  const supabase = await createClient()
  const { error } = await supabase.rpc('register_profile', { p_full_name: parsed.data.full_name, p_phone: parsed.data.phone, p_role: parsed.data.role })
  if (error) return fail(toAppError(error).message)
  redirect('/')
}
