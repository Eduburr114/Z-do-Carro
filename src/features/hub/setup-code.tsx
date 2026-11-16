'use client'

import { useState } from 'react'
import { CopyButton } from '@/components/app/copy-button'
import { ActionForm, SubmitButton } from '@/components/ui/form'
import { newSetupCode } from './actions'

/** Gera e mostra, uma única vez, o código para um novo acesso da equipe da HUB. */
export function SetupCode({ pending }: { pending: boolean }) {
  const [code, setCode] = useState<string | null>(null)
  return (
    <>
      {code ? (
        <div className="mb-4 rounded-(--radius-control) bg-success-surface px-3 py-3">
          <p className="text-sm font-semibold">Código de ativação (aparece só agora)</p>
          <p className="mt-1 flex items-center justify-between gap-2 font-mono text-lg font-semibold break-all">
            {code}
            <CopyButton text={code} />
          </p>
          <p className="mt-1 text-sm text-muted-foreground">
            A pessoa cria a conta em <span className="font-semibold">/cadastro?tipo=hub</span> e informa este código. Ele vale uma vez.
          </p>
        </div>
      ) : pending ? (
        <p className="mb-3 text-sm text-muted-foreground">Há um código gerado e ainda não utilizado. Gerar outro invalida o anterior.</p>
      ) : null}
      <ActionForm action={newSetupCode} onSuccess={(state) => setCode(String(state.data?.code ?? ''))}>
        <SubmitButton variant="secondary">Gerar código de ativação</SubmitButton>
      </ActionForm>
    </>
  )
}
