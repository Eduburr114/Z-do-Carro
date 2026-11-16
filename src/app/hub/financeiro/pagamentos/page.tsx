import type { Metadata } from 'next'
import { AutoRefresh } from '@/components/app/auto-refresh'
import { ActionForm, Field, SubmitButton, TextareaField } from '@/components/ui/form'
import { Badge, Empty, LinkTabs, PageHeader, Panel } from '@/components/ui/primitives'
import { confirmManualPayment, markRefundDone, requestRefund, retryRefund } from '@/features/finance/actions'
import { FinanceTabs } from '@/features/hub/tabs'
import { requireStaff } from '@/lib/auth/session'
import { formatDateTime, formatMoney, paymentStatus } from '@/lib/format'
import { rpc } from '@/lib/rpc'
import type { PaymentStatus } from '@/lib/types'

export const metadata: Metadata = { title: 'Pagamentos' }

type Row = {
  id: string; request_id: string; number: number; customer: string; service: string; kind: 'service' | 'extra'; method: 'pix_asaas' | 'pix_manual'
  status: PaymentStatus; amount: number; fee: number | null; external_id: string | null; provider_status: string | null
  orphan_reason: string | null; manual_reference: string | null; created_at: string; confirmed_at: string | null; last_error: string | null
  refund: { id: string; status: 'requested' | 'processing' | 'done' | 'failed'; reason: string; last_error: string | null } | null
}
const filters = [
  { key: '', label: 'Todos' }, { key: 'claimed', label: 'Pix manual informado' }, { key: 'pending', label: 'Aguardando' },
  { key: 'confirmed', label: 'Confirmados' }, { key: 'refund_pending', label: 'Estorno em andamento' }, { key: 'refunded', label: 'Estornados' }, { key: 'failed', label: 'Com falha' },
]
const orphanLabel: Record<string, string> = { duplicate: 'em duplicidade', late_payment: 'após cancelamento/prazo', amount_mismatch: 'valor divergente' }

export default async function PaymentsPage({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  await requireStaff('finance')
  const { status } = await searchParams
  const current = filters.some((f) => f.key === status) ? (status ?? '') : ''
  const rows = await rpc<Row[]>('finance_payments', { p_status: current || null, p_limit: 200 })
  return (
    <>
      <AutoRefresh seconds={20} />
      <PageHeader title="Financeiro" />
      <FinanceTabs current="/hub/financeiro/pagamentos" />
      <LinkTabs tabs={filters.map((f) => ({ href: `/hub/financeiro/pagamentos${f.key ? `?status=${f.key}` : ''}`, label: f.label }))}
        current={`/hub/financeiro/pagamentos${current ? `?status=${current}` : ''}`} />
      <Panel>
        {rows.length === 0 ? <Empty title="Nenhum pagamento neste filtro" /> : (
          <ul className="divide-y divide-border">
            {rows.map((p) => (
              <li key={p.id} className="px-4 py-3.5 sm:px-5">
                <div className="flex flex-wrap items-center gap-2">
                  <p className="font-semibold">nº {p.number} · {p.service}{p.kind === 'extra' ? ' (adicional)' : ''}</p>
                  <Badge tone={paymentStatus[p.status].tone}>{paymentStatus[p.status].label}</Badge>
                  <Badge>{p.method === 'pix_manual' ? 'Pix manual' : 'Asaas'}</Badge>
                  {p.orphan_reason ? <Badge tone="danger">Fora do fluxo: {orphanLabel[p.orphan_reason]}</Badge> : null}
                </div>
                <p className="mt-0.5 text-sm text-muted-foreground">
                  {formatMoney(p.amount)}{p.fee !== null ? ` · tarifa ${formatMoney(p.fee)}` : ''} · {p.customer} · criado {formatDateTime(p.created_at)}
                  {p.confirmed_at ? ` · confirmado ${formatDateTime(p.confirmed_at)}` : ''}
                </p>
                <p className="text-xs text-muted-foreground">
                  {p.external_id ? `Provedor: ${p.external_id} (${p.provider_status ?? '—'})` : 'Sem cobrança no provedor'}
                  {p.manual_reference ? ` · ref. ${p.manual_reference}` : ''}{p.last_error ? ` · erro: ${p.last_error}` : ''}
                </p>
                {p.refund ? <p className="text-xs text-muted-foreground">Estorno {p.refund.status}{p.refund.last_error ? `: ${p.refund.last_error}` : ''}</p> : null}

                {p.method === 'pix_manual' && ['pending', 'expired', 'cancelled'].includes(p.status) ? (
                  <ActionForm action={confirmManualPayment} successMessage="Pagamento confirmado." className="mt-2 max-w-md">
                    <input type="hidden" name="id" value={p.id} />
                    <Field label="Identificador da transação (E2E) conferido no extrato" name="reference" autoComplete="off" />
                    <SubmitButton size="sm">Confirmar recebimento de {formatMoney(p.amount)}</SubmitButton>
                  </ActionForm>
                ) : null}
                {p.refund && p.method === 'pix_manual' && ['requested', 'processing'].includes(p.refund.status) ? (
                  <ActionForm action={markRefundDone} successMessage="Estorno registrado." className="mt-2 max-w-md">
                    <input type="hidden" name="id" value={p.refund.id} />
                    <Field label="Identificador da devolução Pix feita pela HUB" name="reference" autoComplete="off" />
                    <SubmitButton size="sm" variant="secondary">Registrar devolução</SubmitButton>
                  </ActionForm>
                ) : null}
                {p.refund?.status === 'failed' ? (
                  <ActionForm action={retryRefund} successMessage="Nova tentativa agendada." className="mt-2">
                    <input type="hidden" name="id" value={p.refund.id} />
                    <SubmitButton size="sm" variant="secondary">Tentar o estorno de novo</SubmitButton>
                  </ActionForm>
                ) : null}
                {p.status === 'confirmed' && !p.orphan_reason ? (
                  <details className="mt-2">
                    <summary className="cursor-pointer text-sm font-semibold">Estornar o pedido</summary>
                    <ActionForm action={requestRefund} successMessage="Estorno solicitado." className="mt-2 max-w-md">
                      <input type="hidden" name="id" value={p.request_id} />
                      <TextareaField label="Motivo (fica na auditoria)" name="note" />
                      <SubmitButton size="sm" variant="outline">Estornar todos os pagamentos do pedido</SubmitButton>
                    </ActionForm>
                  </details>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </Panel>
    </>
  )
}
