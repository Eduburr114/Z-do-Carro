import type { Metadata } from 'next'
import { redirect } from 'next/navigation'
import { Wordmark } from '@/components/app/brand'
import { ActionForm, SubmitButton } from '@/components/ui/form'
import { completeProfile } from '@/features/auth/actions'
import { ProfileFields } from '@/features/auth/profile-fields'
import { getSession, homeFor } from '@/lib/auth/session'

export const metadata: Metadata = { title: 'Completar cadastro' }

export default async function CompletePage() {
  const session = await getSession()
  if (!session) redirect('/login')
  if (session.profile) redirect(homeFor[session.profile.role])
  return (
    <div className="min-h-dvh">
      <header className="bg-nav pt-safe text-nav-foreground">
        <div className="mx-auto flex h-16 max-w-md items-center px-5"><Wordmark className="text-xl" /></div>
      </header>
      <main className="mx-auto max-w-md px-5 py-8">
        <h1 className="text-[1.75rem] font-semibold">Falta pouco</h1>
        <p className="mt-1 mb-6 text-muted-foreground">Complete o seu cadastro para começar.</p>
        <ActionForm action={completeProfile} resetOnSuccess={false}>
          <ProfileFields defaultRole="customer" />
          <SubmitButton size="lg" className="w-full">Continuar</SubmitButton>
        </ActionForm>
      </main>
    </div>
  )
}
