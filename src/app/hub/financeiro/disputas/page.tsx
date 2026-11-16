import type { Metadata } from 'next'
import { ActionForm, SelectField, SubmitButton, TextareaField } from '@/components/ui/form'
import { Badge, Empty, PageHeader, Panel } from '@/components/ui/primitives'
import { resolveDispute } from '@/features/finance/actions'
import { FinanceTabs } from '@/features/hub/tabs'
import { requireStaff } from '@/lib/auth/session'
import { formatDateTime, formatMoney } from '@/lib/format'
import { rpc } from '@/lib/rpc'

export const metadata: Metadata = { title: 'Disputas' }

type Dispute = {
  id: string; request_id: string; number: number; service: string; customer: string; provider: string | null; total: number; provider_net: number
  reason: string; opened_role: string; status: 'open' | 'resolved_provider' | 'resolved_customer'; created_at: string; resolution_note: string | null; resolved_at: string | null
}
const statusLabel = { open: 'Aberta', resolved_provider: 'A favor do prestador', resolved_customer: 'A favor do cliente' } as const

export default async function DisputesPage() {
  await requireStaff('finance')
  const disputes = await rpc<Dispute[]>('finance_disputes')
  return (
    <>
      <PageHeader title="Financeiro" />
      <FinanceTabs current="/hub/financeiro/disputas" />
      <p className="mb-3 text-sm text-muted-foreground">Enquanto a disputa está aberta, o repasse fica retido. A favor do cliente: estorno integral. A favor do prestador: o repasse é agendado.</p>
      <Panel>
        {disputes.length === 0 ? <Empty title="Nenhuma disputa" /> : (
          <ul className="divide-y divide-border">
            {disputes.map((d) => (
              <li key={d.id} className="px-4 py-3.5 sm:px-5">
                <div className="flex flex-wrap items-center gap-2">
                  <p className="font-semibold">nº {d.number} · {d.service}</p>
                  <Badge tone={d.status === 'open' ? 'danger' : 'neutral'}>{statusLabel[d.status]}</Badge>
                </div>
                <p className="mt-0.5 text-sm text-muted-foreground">
                  Aberta por {d.opened_role === 'customer' ? 'cliente' : 'prestador'} em {formatDateTime(d.created_at)} · cliente {d.customer} · prestador {d.provider ?? '—'} · pago {formatMoney(d.total)} · líquido {formatMoney(d.provider_net)}
                </p>
                <blockquote className="mt-2 border-l-2 border-border pl-3 text-sm">{d.reason}</blockquote>
                {d.status === 'open' ? (
                  <ActionForm action={resolveDispute} successMessage="Decisão registrada." className="mt-3 max-w-lg">
                    <input type="hidden" name="id" value={d.id} />
                    <SelectField label="Decisão" name="outcome" defaultValue="provider">
                      <option value="provider">A favor do prestador (libera o repasse)</option>
                      <option value="customer">A favor do cliente (estorno integral)</option>
                    </SelectField>
                    <TextareaField label="Fundamentação (enviada às partes e registrada)" name="note" />
                    <SubmitButton size="sm">Registrar decisão</SubmitButton>
                  </ActionForm>
                ) : (
                  <p className="mt-2 text-sm">Decisão em {formatDateTime(d.resolved_at)}: {d.resolution_note}</p>
                )}
              </li>
            ))}
          </ul>
        )}
      </Panel>
    </>
  )
}
