import type { Metadata } from 'next'
import { AutoRefresh } from '@/components/app/auto-refresh'
import { ActionForm, Field, SelectField, SubmitButton, TextareaField } from '@/components/ui/form'
import { Badge, Empty, LinkTabs, PageHeader, Panel } from '@/components/ui/primitives'
import { holdPayout, markPayoutPaid, releasePayout, resolveUncertainPayout, retryPayout } from '@/features/finance/actions'
import { FinanceTabs } from '@/features/hub/tabs'
import { requireStaff } from '@/lib/auth/session'
import { formatDateTime, formatMoney, holdReason, payoutStatus } from '@/lib/format'
import { requestTime } from '@/lib/clock'
import { rpc } from '@/lib/rpc'
import type { PayoutStatus } from '@/lib/types'

export const metadata: Metadata = { title: 'Repasses' }

type Row = {
  id: string; request_id: string; number: number; provider: string; provider_id: string; amount: number; status: PayoutStatus
  scheduled_for: string; attempts: number; next_attempt_at: string | null; uncertain: boolean; final_failure: boolean
  fail_reason: string | null; hold_reason: string | null; external_id: string | null; external_status: string | null
  completed_at: string | null; manual_reference: string | null
}
const filters = [
  { key: '', label: 'Todos' }, { key: 'scheduled', label: 'Agendados' }, { key: 'on_hold', label: 'Retidos' },
  { key: 'processing', label: 'Em processamento' }, { key: 'failed', label: 'Com falha' }, { key: 'completed', label: 'Transferidos' },
]

export default async function PayoutsPage({ searchParams }: { searchParams: Promise<{ status?: string; prestador?: string }> }) {
  await requireStaff('finance')
  const { status, prestador } = await searchParams
  const current = filters.some((f) => f.key === status) ? (status ?? '') : ''
  const [all, { settings }] = await Promise.all([
    rpc<Row[]>('finance_payouts', { p_status: current || null, p_limit: 300 }),
    rpc<{ settings: { payout_mode: 'asaas' | 'manual' } }>('finance_settings'),
  ])
  const rows = prestador ? all.filter((r) => r.provider_id === prestador) : all
  const now = requestTime()
  return (
    <>
      <AutoRefresh seconds={20} />
      <PageHeader title="Financeiro" />
      <FinanceTabs current="/hub/financeiro/repasses" />
      <LinkTabs tabs={filters.map((f) => ({ href: `/hub/financeiro/repasses${f.key ? `?status=${f.key}` : ''}`, label: f.label }))}
        current={`/hub/financeiro/repasses${current ? `?status=${current}` : ''}`} />
      <p className="mb-3 text-sm text-muted-foreground">
        {settings.payout_mode === 'asaas'
          ? 'Os repasses vencidos saem sozinhos por transferência Pix, uma única vez cada. Falhas têm novas tentativas com espera; sem resposta do provedor, nada é refeito antes da conciliação.'
          : 'Repasse manual: pague por fora no vencimento e registre aqui o identificador do Pix enviado.'}
      </p>
      <Panel>
        {rows.length === 0 ? <Empty title="Nenhum repasse neste filtro" /> : (
          <ul className="divide-y divide-border">
            {rows.map((p) => (
              <li key={p.id} className="px-4 py-3.5 sm:px-5">
                <div className="flex flex-wrap items-center gap-2">
                  <p className="font-semibold">nº {p.number} · {p.provider}</p>
                  <Badge tone={payoutStatus[p.status].tone}>{p.final_failure ? 'Falha definitiva' : payoutStatus[p.status].label}</Badge>
                  {p.uncertain ? <Badge tone="danger">Sem confirmação do provedor</Badge> : null}
                </div>
                <p className="mt-0.5 text-sm text-muted-foreground tabular-nums">
                  {formatMoney(p.amount)} · {p.status === 'completed' ? `transferido ${formatDateTime(p.completed_at)}` : `previsto ${formatDateTime(p.scheduled_for)}`}
                  {p.attempts ? ` · ${p.attempts} tentativa(s)` : ''}
                  {p.status === 'failed' && p.next_attempt_at && !p.final_failure ? ` · próxima ${formatDateTime(p.next_attempt_at)}` : ''}
                </p>
                {p.status === 'on_hold' ? <p className="text-sm text-warning">{holdReason(p.hold_reason)}</p> : null}
                {p.fail_reason && p.status !== 'completed' ? <p className="text-sm text-danger">{p.fail_reason}</p> : null}
                <p className="text-xs text-muted-foreground">
                  {p.external_id ? `Transferência ${p.external_id} (${p.external_status ?? '—'})` : ''}{p.manual_reference ? ` · ref. ${p.manual_reference}` : ''}
                </p>

                <div className="mt-2 flex flex-wrap gap-2">
                  {p.status === 'on_hold' && p.hold_reason !== 'dispute' && p.hold_reason !== 'no_account' ? (
                    <ActionForm action={releasePayout} successMessage="Repasse liberado.">
                      <input type="hidden" name="id" value={p.id} />
                      <SubmitButton size="sm" variant="secondary">Liberar</SubmitButton>
                    </ActionForm>
                  ) : null}
                  {p.status === 'failed' && p.final_failure ? (
                    <ActionForm action={retryPayout} successMessage="Nova tentativa agendada.">
                      <input type="hidden" name="id" value={p.id} />
                      <SubmitButton size="sm">Tentar de novo</SubmitButton>
                    </ActionForm>
                  ) : null}
                </div>
                {['scheduled', 'failed'].includes(p.status) ? (
                  <details className="mt-2">
                    <summary className="cursor-pointer text-sm font-semibold">Reter este repasse</summary>
                    <ActionForm action={holdPayout} successMessage="Repasse retido." className="mt-2 max-w-md">
                      <input type="hidden" name="id" value={p.id} />
                      <TextareaField label="Motivo (fica na auditoria)" name="reason" />
                      <SubmitButton size="sm" variant="outline">Reter</SubmitButton>
                    </ActionForm>
                  </details>
                ) : null}
                {settings.payout_mode === 'manual' && ['scheduled', 'failed'].includes(p.status) && new Date(p.scheduled_for).getTime() <= now ? (
                  <ActionForm action={markPayoutPaid} successMessage="Repasse registrado." className="mt-2 max-w-md">
                    <input type="hidden" name="id" value={p.id} />
                    <Field label="Identificador do Pix enviado ao prestador" name="reference" autoComplete="off" />
                    <SubmitButton size="sm">Registrar repasse de {formatMoney(p.amount)}</SubmitButton>
                  </ActionForm>
                ) : null}
                {p.status === 'processing' && p.uncertain ? (
                  <ActionForm action={resolveUncertainPayout} successMessage="Conciliação registrada." className="mt-2 max-w-md">
                    <input type="hidden" name="id" value={p.id} />
                    <SelectField label="No painel do Asaas, a transferência saiu?" name="sent" defaultValue="no">
                      <option value="no">Não saiu (pode tentar de novo)</option>
                      <option value="yes">Saiu (informar o identificador)</option>
                    </SelectField>
                    <Field label="Identificador da transferência (se saiu)" name="transfer_id" autoComplete="off" />
                    <TextareaField label="O que foi conferido" name="note" />
                    <SubmitButton size="sm">Registrar</SubmitButton>
                  </ActionForm>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </Panel>
    </>
  )
}
