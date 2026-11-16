import type { Metadata } from 'next'
import { redirect } from 'next/navigation'
import { PlainPage } from '@/components/app/plain-page'
import { getSession } from '@/lib/auth/session'
import { NewPasswordForm } from './new-password-form'

export const metadata: Metadata = { title: 'Nova senha' }

export default async function NewPasswordPage() {
  if (!(await getSession())?.recovery) redirect('/recuperar')
  return (
    <PlainPage>
      <h1 className="text-[1.75rem] font-semibold">Criar nova senha</h1>
      <p className="mt-1 mb-6 text-muted-foreground">Escolha uma senha com ao menos 8 caracteres.</p>
      <NewPasswordForm />
    </PlainPage>
  )
}
