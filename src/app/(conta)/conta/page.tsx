import type { Metadata } from 'next'
import Link from 'next/link'
import { SectionTitle } from '@/components/app/bits'
import { ActionForm, Field, SubmitButton } from '@/components/ui/form'
import { Panel } from '@/components/ui/primitives'
import { buttonVariants } from '@/components/ui/button'
import { updateProfile } from '@/features/account/actions'
import { signOut } from '@/features/auth/actions'
import { PushToggle } from '@/features/notifications/push-toggle'
import { requireUser } from '@/lib/auth/session'
import { env } from '@/lib/env'
import { formatPhone } from '@/lib/format'

export const metadata: Metadata = { title: 'Conta' }

export default async function AccountPage() {
  const session = await requireUser()
  return (
    <>
      <h1 className="text-2xl font-semibold">Conta</h1>
      <p className="mt-1 text-muted-foreground">{session.email}</p>

      <SectionTitle>Seus dados</SectionTitle>
      <Panel className="px-4 py-4">
        <ActionForm action={updateProfile} successMessage="Dados salvos." resetOnSuccess={false}>
          <Field label="Nome completo" name="full_name" defaultValue={session.profile.full_name} autoComplete="name" required />
          <Field label="Celular com DDD" name="phone" type="tel" inputMode="tel" defaultValue={formatPhone(session.profile.phone)} required />
          <SubmitButton variant="secondary">Salvar</SubmitButton>
        </ActionForm>
      </Panel>

      <SectionTitle>Avisos neste aparelho</SectionTitle>
      <Panel className="px-4 py-4">
        <PushToggle vapidKey={env().NEXT_PUBLIC_VAPID_PUBLIC_KEY ?? null} />
      </Panel>

      <SectionTitle>Segurança</SectionTitle>
      <Panel className="flex flex-col gap-3 px-4 py-4">
        <Link href="/recuperar" className={buttonVariants({ variant: 'outline' })}>Trocar a senha</Link>
        <p className="-mt-1 text-sm text-muted-foreground">Enviamos um link para o seu e-mail; a troca é feita por ele.</p>
        <form action={signOut}>
          <button type="submit" className={buttonVariants({ variant: 'outline', className: 'w-full text-danger' })}>Sair da conta</button>
        </form>
      </Panel>

      <p className="mt-8 text-sm text-muted-foreground">
        <Link href="/termos" className="font-semibold text-primary underline-offset-4 hover:underline">Termos de Uso</Link>
        {' · '}
        <Link href="/privacidade" className="font-semibold text-primary underline-offset-4 hover:underline">Política de Privacidade</Link>
      </p>
    </>
  )
}
