import type { Metadata } from 'next'
import Link from 'next/link'
import { ActionForm, Field, SubmitButton } from '@/components/ui/form'
import { signIn } from '@/features/auth/actions'

export const metadata: Metadata = { title: 'Entrar' }

export default function LoginPage() {
  return (
    <>
      <h1 className="text-[1.75rem] font-semibold">Entrar</h1>
      <p className="mt-1 mb-6 text-muted-foreground">Use o e-mail e a senha da sua conta.</p>
      <ActionForm action={signIn} resetOnSuccess={false}>
        <Field label="E-mail" name="email" type="email" autoComplete="username" inputMode="email" autoCapitalize="none" required />
        <Field label="Senha" name="password" type="password" autoComplete="current-password" required />
        <SubmitButton size="lg" className="w-full">Entrar</SubmitButton>
      </ActionForm>
      <p className="mt-4 text-sm">
        <Link href="/recuperar" className="font-semibold text-primary underline-offset-4 hover:underline">Esqueci minha senha</Link>
      </p>
      <p className="mt-8 text-sm text-muted-foreground">
        Ainda não tem conta?{' '}
        <Link href="/cadastro" className="font-semibold text-primary underline-offset-4 hover:underline">Criar conta</Link>
      </p>
    </>
  )
}
