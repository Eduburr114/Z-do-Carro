'use server'

import { redirect } from 'next/navigation'
import { z } from 'zod'
import type { ActionState } from '@/lib/action-state'
import { getSession } from '@/lib/auth/session'
import { toAppError } from '@/lib/rpc'
import { appOrigin, clearFailures, clientIp, limiterKey, registerFailure, underRateLimit, withinRateLimit } from '@/lib/security'
import { createClient } from '@/lib/supabase/server'
import { TERMS_VERSION } from '@/lib/terms'

const fail = (message: string, fieldErrors?: Record<string, string>): ActionState => ({ ok: false, message, fieldErrors, at: Date.now() })

function fieldErrorsOf(error: z.ZodError): Record<string, string> {
  const fieldErrors: Record<string, string> = {}
  for (const issue of error.issues) fieldErrors[String(issue.path[0])] ??= issue.message
  return fieldErrors
}

const zPhone = z.string().transform((v) => v.replace(/\D/g, '')).pipe(z.string().regex(/^\d{10,11}$/, 'Informe o telefone com DDD.'))
const zName = z.string().trim().min(3, 'Informe o nome completo.').max(120)
const zNewPassword = z.string().min(8, 'Use ao menos 8 caracteres.').max(128)
const zTerms = z.literal('on', 'É preciso aceitar os termos para continuar.')

const signInSchema = z.object({ email: z.email().max(160), password: z.string().min(1).max(128) })

export async function signIn(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = signInSchema.safeParse({ email: formData.get('email'), password: formData.get('password') })
  if (!parsed.success) return fail('Informe e-mail e senha.')

  // Limite de falhas por e-mail+IP (força bruta em uma conta) e por IP (varredura
  // de contas). Acertos não contam e zeram o contador da conta.
  const ip = await clientIp()
  const accountKey = limiterKey('login', ip, parsed.data.email)
  const ipKey = limiterKey('login-ip', ip)
  if (!((await underRateLimit(accountKey, 8, 15 * 60)) && (await underRateLimit(ipKey, 40, 15 * 60)))) {
    return fail('Muitas tentativas. Aguarde 15 minutos e tente de novo.')
  }
  const supabase = await createClient()
  const { error } = await supabase.auth.signInWithPassword(parsed.data)
  if (error) {
    await registerFailure(accountKey, 8, 15 * 60)
    await registerFailure(ipKey, 40, 15 * 60)
    // Mesma mensagem para e-mail inexistente e senha errada.
    return fail('E-mail ou senha incorretos.')
  }
  await clearFailures(accountKey)
  redirect('/')
}

export async function signOut(): Promise<void> {
  const supabase = await createClient()
  await supabase.auth.signOut({ scope: 'local' })
  redirect('/')
}

const profileSchema = z.object({
  full_name: zName,
  phone: zPhone,
  role: z.enum(['customer', 'provider'], 'Escolha como você vai usar o aplicativo.'),
  terms: zTerms,
})

const signUpSchema = profileSchema.extend({
  email: z.email('Informe um e-mail válido.').max(160),
  password: zNewPassword,
})

export async function signUp(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = signUpSchema.safeParse(Object.fromEntries(formData))
  if (!parsed.success) return fail('Confira os campos destacados.', fieldErrorsOf(parsed.error))
  if (!(await withinRateLimit(limiterKey('cadastro', await clientIp()), 30, 60 * 60))) {
    return fail('Muitos cadastros a partir desta rede. Tente de novo mais tarde.')
  }
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
  const registered = await supabase.rpc('register_profile', { p_full_name: full_name, p_phone: phone, p_role: role, p_terms_version: TERMS_VERSION })
  if (registered.error) return fail(toAppError(registered.error).message)
  redirect('/')
}

/** Quem confirmou o e-mail e ainda não tem cadastro termina por aqui. */
export async function completeProfile(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = profileSchema.safeParse(Object.fromEntries(formData))
  if (!parsed.success) return fail('Confira os campos destacados.', fieldErrorsOf(parsed.error))
  const supabase = await createClient()
  const { error } = await supabase.rpc('register_profile', {
    p_full_name: parsed.data.full_name, p_phone: parsed.data.phone, p_role: parsed.data.role, p_terms_version: TERMS_VERSION,
  })
  if (error) return fail(toAppError(error).message)
  redirect('/')
}

const hubSchema = z.object({ full_name: zName, phone: zPhone, code: z.string().trim().min(8, 'Informe o código de ativação.').max(60) })

/** Cria a conta e já ativa o acesso da equipe da HUB com o código de uso único. */
export async function signUpHub(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = hubSchema.extend({ email: z.email('Informe um e-mail válido.').max(160), password: zNewPassword }).safeParse(Object.fromEntries(formData))
  if (!parsed.success) return fail('Confira os campos destacados.', fieldErrorsOf(parsed.error))
  if (!(await withinRateLimit(limiterKey('ativacao', await clientIp()), 10, 60 * 60))) return fail('Muitas tentativas. Aguarde uma hora.')
  const supabase = await createClient()
  const { data, error } = await supabase.auth.signUp({ email: parsed.data.email, password: parsed.data.password })
  if (error) {
    if (error.code === 'user_already_exists') return fail('Confira os campos destacados.', { email: 'Já existe uma conta com este e-mail. Entre nela e use o código.' })
    return fail('Não foi possível criar a conta agora. Tente de novo em instantes.')
  }
  if (!data.session) return fail('Conta criada. Confirme o e-mail pelo link enviado, entre no aplicativo e informe o código de ativação.')
  const claimed = await supabase.rpc('claim_hub_admin', { p_code: parsed.data.code, p_full_name: parsed.data.full_name, p_phone: parsed.data.phone })
  // A conta existe mas o código não valeu: a pessoa segue para a tela do código.
  if (claimed.error) redirect('/ativar-hub')
  redirect('/hub')
}

/** Acesso da equipe da HUB, com o código de ativação de uso único. */
export async function claimHubAccess(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = hubSchema.safeParse(Object.fromEntries(formData))
  if (!parsed.success) return fail('Confira os campos destacados.', fieldErrorsOf(parsed.error))
  if (!(await withinRateLimit(limiterKey('ativacao', await clientIp()), 10, 60 * 60))) return fail('Muitas tentativas. Aguarde uma hora.')
  const supabase = await createClient()
  const { error } = await supabase.rpc('claim_hub_admin', { p_code: parsed.data.code, p_full_name: parsed.data.full_name, p_phone: parsed.data.phone })
  if (error) return fail(toAppError(error).message)
  redirect('/hub')
}

export async function requestPasswordReset(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = z.object({ email: z.email('Informe um e-mail válido.').max(160) }).safeParse({ email: formData.get('email') })
  if (!parsed.success) return fail('Confira os campos destacados.', fieldErrorsOf(parsed.error))
  const ip = await clientIp()
  const allowed = (await withinRateLimit(limiterKey('recuperar', parsed.data.email), 3, 60 * 60)) && (await withinRateLimit(limiterKey('recuperar-ip', ip), 10, 60 * 60))
  if (allowed) {
    const supabase = await createClient()
    await supabase.auth.resetPasswordForEmail(parsed.data.email, { redirectTo: `${await appOrigin()}/auth/confirmar` })
  }
  // Mesma resposta em qualquer caso: não revela se o e-mail tem conta.
  return { ok: true, at: Date.now() }
}

const newPasswordSchema = z
  .object({ password: zNewPassword, confirm: z.string() })
  .refine((v) => v.password === v.confirm, { path: ['confirm'], message: 'As senhas não coincidem.' })

/** Define a nova senha da sessão atual (aberta pelo link de recuperação ou já logada). */
export async function setNewPassword(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = newPasswordSchema.safeParse(Object.fromEntries(formData))
  if (!parsed.success) return fail('Confira os campos destacados.', fieldErrorsOf(parsed.error))
  // Só uma sessão aberta pelo link enviado ao e-mail troca a senha: quem apenas
  // está com o aparelho desbloqueado em mãos não consegue.
  if (!(await getSession())?.recovery) return fail('O link expirou. Peça um novo em "Esqueci minha senha".')
  const supabase = await createClient()
  const { error } = await supabase.auth.updateUser({ password: parsed.data.password })
  if (error) {
    const weak = error.code === 'weak_password' || error.code === 'same_password'
    return fail(weak ? 'Escolha uma senha mais forte e diferente da atual.' : 'Não foi possível alterar a senha. Peça um novo link.')
  }
  await supabase.auth.signOut({ scope: 'others' })
  return { ok: true, at: Date.now() }
}
