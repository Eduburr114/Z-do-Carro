import type { Metadata } from 'next'
import Link from 'next/link'
import { Notice } from '@/components/ui/primitives'
import { RecoverForm } from './recover-form'

export const metadata: Metadata = { title: 'Recuperar senha' }

export default async function RecoverPage({ searchParams }: { searchParams: Promise<{ erro?: string }> }) {
  const { erro } = await searchParams
  return (
    <>
      <h1 className="text-[1.75rem] font-semibold">Esqueci minha senha</h1>
      <p className="mt-1 mb-6 text-muted-foreground">Informe o e-mail da conta. Enviaremos um link para criar uma nova senha.</p>
      {erro ? <Notice tone="danger" className="mb-5">O link é inválido ou expirou. Peça um novo abaixo.</Notice> : null}
      <RecoverForm />
      <p className="mt-8 text-sm text-muted-foreground">
        Lembrou?{' '}
        <Link href="/login" className="font-semibold text-primary underline-offset-4 hover:underline">Voltar para o login</Link>
      </p>
    </>
  )
}
