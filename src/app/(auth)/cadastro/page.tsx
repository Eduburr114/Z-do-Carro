import type { Metadata } from 'next'
import Link from 'next/link'
import { SignUpForm } from './signup-form'

export const metadata: Metadata = { title: 'Criar conta' }

export default async function SignUpPage({ searchParams }: { searchParams: Promise<{ tipo?: string }> }) {
  const { tipo } = await searchParams
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
