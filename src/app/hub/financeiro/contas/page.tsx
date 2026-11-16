import type { Metadata } from 'next'
import { ActionForm, SubmitButton, TextareaField } from '@/components/ui/form'
import { Badge, Empty, PageHeader, Panel } from '@/components/ui/primitives'
import { reviewAccount } from '@/features/finance/actions'
import { FinanceTabs } from '@/features/hub/tabs'
import { requireStaff } from '@/lib/auth/session'
import { formatDateTime, formatDoc } from '@/lib/format'
import { rpc } from '@/lib/rpc'

export const metadata: Metadata = { title: 'Contas Pix' }

type Account = {
  id: string; provider: string; legal_name: string; doc_number: string; pix_key_type: string; pix_key: string; holder_name: string; holder_doc: string
  status: 'pending_review' | 'active'; created_at: string; reviewed_at: string | null; usable_from: string | null
}

export default async function AccountsPage() {
  await requireStaff('finance')
  const accounts = await rpc<Account[]>('finance_accounts')
  return (
    <>
      <PageHeader title="Financeiro" />
      <FinanceTabs current="/hub/financeiro/contas" />
      <p className="mb-3 text-sm text-muted-foreground">
        A conta precisa ser do próprio prestador (mesmo CPF/CNPJ do credenciamento). Na dúvida, confirme com ele por telefone antes de aprovar: trocar a conta de recebimento é um golpe comum.
      </p>
      <Panel>
        {accounts.length === 0 ? <Empty title="Nenhuma conta cadastrada" /> : (
          <ul className="divide-y divide-border">
            {accounts.map((a) => (
              <li key={a.id} className="px-4 py-3.5 sm:px-5">
                <div className="flex flex-wrap items-center gap-2">
                  <p className="font-semibold">{a.provider}</p>
                  <Badge tone={a.status === 'active' ? 'success' : 'warning'}>{a.status === 'active' ? 'Ativa' : 'A conferir'}</Badge>
                </div>
                <p className="mt-0.5 text-sm">{a.pix_key_type}: <span className="font-mono">{a.pix_key}</span></p>
                <p className="text-sm text-muted-foreground">
                  Titular {a.holder_name} · {formatDoc(a.holder_doc)} · credenciamento {a.legal_name} ({formatDoc(a.doc_number)}) · enviada {formatDateTime(a.created_at)}
                  {a.usable_from ? ` · recebe a partir de ${formatDateTime(a.usable_from)}` : ''}
                </p>
                {a.status === 'pending_review' ? (
                  <div className="mt-2 flex flex-wrap items-start gap-3">
                    <ActionForm action={reviewAccount} successMessage="Conta aprovada.">
                      <input type="hidden" name="id" value={a.id} />
                      <input type="hidden" name="decision" value="approve" />
                      <SubmitButton size="sm">Aprovar</SubmitButton>
                    </ActionForm>
                    <details>
                      <summary className="cursor-pointer text-sm font-semibold">Recusar</summary>
                      <ActionForm action={reviewAccount} successMessage="Conta recusada." className="mt-2 w-72">
                        <input type="hidden" name="id" value={a.id} />
                        <input type="hidden" name="decision" value="reject" />
                        <TextareaField label="Motivo (enviado ao prestador)" name="note" />
                        <SubmitButton size="sm" variant="outline">Recusar conta</SubmitButton>
                      </ActionForm>
                    </details>
                  </div>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </Panel>
    </>
  )
}
