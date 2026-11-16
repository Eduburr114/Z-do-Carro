'use client'

import { useState } from 'react'
import { ActionForm, CheckboxField, Field, SubmitButton } from '@/components/ui/form'
import { Notice } from '@/components/ui/primitives'
import { signUp } from '@/features/auth/actions'
import { ProfileFields } from '@/features/auth/profile-fields'

export function SignUpForm({ defaultRole }: { defaultRole: 'customer' | 'provider' }) {
  const [confirm, setConfirm] = useState(false)
  if (confirm) {
    return (
      <Notice tone="success" title="Conta criada">
        Enviamos um link de confirmação para o seu e-mail. Abra o link e depois entre no aplicativo.
      </Notice>
    )
  }
  return (
    <ActionForm action={signUp} resetOnSuccess={false} onSuccess={(state) => setConfirm(state.message === 'confirm_email')}>
      <ProfileFields defaultRole={defaultRole} />
      <Field label="E-mail" name="email" type="email" autoComplete="username" inputMode="email" autoCapitalize="none" required />
      <Field label="Senha" name="password" type="password" autoComplete="new-password" hint="Ao menos 8 caracteres." required />
      <CheckboxField
        name="terms"
        label="Concordo com o uso dos meus dados para o atendimento"
        hint="Nome, telefone e localização são usados só para viabilizar e dar segurança aos serviços (LGPD)."
      />
      <SubmitButton size="lg" className="w-full">Criar conta</SubmitButton>
    </ActionForm>
  )
}
