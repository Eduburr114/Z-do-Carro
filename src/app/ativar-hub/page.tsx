import type { Metadata } from 'next'
import Link from 'next/link'
import { redirect } from 'next/navigation'
import { PlainPage } from '@/components/app/plain-page'
import { ActionForm, Field, SubmitButton } from '@/components/ui/form'
import { claimHubAccess } from '@/features/auth/actions'
import { getSession, homeFor } from '@/lib/auth/session'

export const metadata: Metadata = { title: 'Acesso da equipe HUB' }

export default async function ClaimHubPage() {
  const session = await getSession()
  if (!session) redirect('/login')
  if (session.profile) redirect(homeFor[session.profile.role])
  return (
    <PlainPage>
      <h1 className="text-[1.75rem] font-semibold">Acesso da equipe HUB</h1>
      <p className="mt-1 mb-6 text-muted-foreground">Informe o código de ativação que você recebeu. Ele vale uma única vez.</p>
      <ActionForm action={claimHubAccess} resetOnSuccess={false}>
        <Field label="Nome completo" name="full_name" autoComplete="name" required />
        <Field label="Celular com DDD" name="phone" type="tel" inputMode="tel" autoComplete="tel-national" required />
        <Field label="Código de ativação" name="code" autoCapitalize="characters" autoComplete="off" required />
        <SubmitButton size="lg" className="w-full">Ativar acesso</SubmitButton>
      </ActionForm>
      <p className="mt-8 text-sm text-muted-foreground">
        Não é da equipe?{' '}
        <Link href="/completar" className="font-semibold text-primary underline-offset-4 hover:underline">Voltar</Link>
      </p>
    </PlainPage>
  )
}
