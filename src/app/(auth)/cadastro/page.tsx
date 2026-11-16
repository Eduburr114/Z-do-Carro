import type { Metadata } from 'next'
import Link from 'next/link'
import { ActionForm, Field, SubmitButton } from '@/components/ui/form'
import { signUpHub } from '@/features/auth/actions'
import { SignUpForm } from './signup-form'

export const metadata: Metadata = { title: 'Criar conta' }

export default async function SignUpPage({ searchParams }: { searchParams: Promise<{ tipo?: string }> }) {
  const { tipo } = await searchParams
  if (tipo === 'hub') {
    return (
      <>
        <h1 className="text-[1.75rem] font-semibold">Acesso da equipe HUB</h1>
        <p className="mt-1 mb-6 text-muted-foreground">Crie a sua conta com o código de ativação que você recebeu.</p>
        <ActionForm action={signUpHub} resetOnSuccess={false}>
          <Field label="Nome completo" name="full_name" autoComplete="name" required />
          <Field label="Celular com DDD" name="phone" type="tel" inputMode="tel" autoComplete="tel-national" required />
          <Field label="E-mail" name="email" type="email" autoComplete="username" inputMode="email" autoCapitalize="none" required />
          <Field label="Senha" name="password" type="password" autoComplete="new-password" hint="Ao menos 8 caracteres." required />
          <Field label="Código de ativação" name="code" autoCapitalize="characters" autoComplete="off" required />
          <SubmitButton size="lg" className="w-full">Criar acesso</SubmitButton>
        </ActionForm>
      </>
    )
  }
  return (
    <>
      <h1 className="text-[1.75rem] font-semibold">Criar conta</h1>
      <p className="mt-1 mb-6 text-muted-foreground">Leva menos de um minuto.</p>
      <SignUpForm defaultRole={tipo === 'prestador' ? 'provider' : 'customer'} />
      <p className="mt-8 text-sm text-muted-foreground">
        Já tem conta?{' '}
        <Link href="/login" className="font-semibold text-primary underline-offset-4 hover:underline">Entrar</Link>
      </p>
    </>
  )
}
