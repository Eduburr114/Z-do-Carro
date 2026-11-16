'use client'

import { useState } from 'react'
import { ActionForm, Field, SubmitButton } from '@/components/ui/form'
import { Notice } from '@/components/ui/primitives'
import { requestPasswordReset } from '@/features/auth/actions'

export function RecoverForm() {
  const [sent, setSent] = useState(false)
  if (sent) {
    return (
      <Notice tone="success" title="Confira o seu e-mail">
        Se houver uma conta com esse endereço, o link chega em instantes. Ele vale por uma hora. Veja também a caixa de spam.
      </Notice>
    )
  }
  return (
    <ActionForm action={requestPasswordReset} onSuccess={() => setSent(true)}>
      <Field label="E-mail" name="email" type="email" autoComplete="username" inputMode="email" autoCapitalize="none" required />
      <SubmitButton size="lg" className="w-full">Enviar link</SubmitButton>
    </ActionForm>
  )
}
