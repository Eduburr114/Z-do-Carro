'use client'

import { useState } from 'react'
import Link from 'next/link'
import { buttonVariants } from '@/components/ui/button'
import { ActionForm, Field, SubmitButton } from '@/components/ui/form'
import { Notice } from '@/components/ui/primitives'
import { setNewPassword } from '@/features/auth/actions'

export function NewPasswordForm() {
  const [done, setDone] = useState(false)
  if (done) {
    return (
      <>
        <Notice tone="success" title="Senha alterada">Os outros aparelhos conectados a esta conta foram desconectados.</Notice>
        <Link href="/" className={buttonVariants({ size: 'lg', className: 'mt-5 w-full' })}>Continuar</Link>
      </>
    )
  }
  return (
    <ActionForm action={setNewPassword} onSuccess={() => setDone(true)}>
      <Field label="Nova senha" name="password" type="password" autoComplete="new-password" required />
      <Field label="Repita a nova senha" name="confirm" type="password" autoComplete="new-password" required />
      <SubmitButton size="lg" className="w-full">Salvar nova senha</SubmitButton>
    </ActionForm>
  )
}
