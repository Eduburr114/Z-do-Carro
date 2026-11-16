import type { Metadata } from 'next'
import Link from 'next/link'
import { SectionTitle } from '@/components/app/bits'
import { buttonVariants } from '@/components/ui/button'
import { Notice, PageHeader, Panel, Stat, Table } from '@/components/ui/primitives'
import { DailyChart } from '@/features/finance/daily-chart'
import { FinanceTabs } from '@/features/hub/tabs'
import { requireStaff } from '@/lib/auth/session'
import { financeDeps } from '@/lib/finance/server'
import { formatMoney, formatPercent } from '@/lib/format'
import { rpc } from '@/lib/rpc'

export const metadata: Metadata = { title: 'Financeiro' }

type Dashboard = {
  period: { from: string; to: string }
  volume: number; payments_count: number; revenue: number; fees: number; subsidy: number; net_revenue: number; refunded: number
  balances: { cash_gateway: number; customer_funds_held: number; provider_payable: number; provider_receivable: number }
  payouts: { scheduled_count: number; scheduled: number; on_hold: number; on_hold_count: number; processing: number; failed_count: number; completed_period: number; completed_period_count: number; avg_days_to_payout: number | null }
  disputes_open: number
  accounts_pending: number
  failures: { payouts_final: number; payouts_uncertain: number; refunds_failed: number; webhooks_failed: number; emails_failed: number; payments_failed: number }
  kpis: { avg_ticket: number | null; take_rate: number | null; conversion: number | null; refund_rate: number | null }
  by_category: { name: string; count: number; volume: number; revenue: number }[]
  by_provider: { name: string; provider_id: string; jobs: number; earned: number; paid: number; pending: number }[]
  daily: { day: string; volume: number; count: number }[]
}

const isDate = (v: unknown): v is string => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v)

/** Saldo informado pelo provedor, para comparar com o razão. Nunca derruba a página. */
async function gatewayBalance(): Promise<number | null> {
  const gateway = financeDeps().gateway
  if (!gateway) return null
  try {
    return (await gateway.getBalance()).balance
  } catch {
    return null
  }
}

export default async function FinanceDashboard({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  await requireStaff('finance')
  const params = await searchParams
  const from = isDate(params.de) ? params.de : null
  const to = isDate(params.ate) ? params.ate : null
  const [d, balance] = await Promise.all([rpc<Dashboard>('finance_dashboard', { p_from: from, p_to: to }), gatewayBalance()])
  const failures = Object.values(d.failures).reduce((a, b) => a + Number(b), 0)
  const pct = (v: number | null) => (v === null ? '—' : formatPercent(v))
  return (
    <>
      <PageHeader title="Financeiro" description="Valores confirmados pelo provedor e lançados no razão contábil." />
      <FinanceTabs current="/hub/financeiro" />

      <form className="mb-5 flex flex-wrap items-end gap-2" method="get">
        <label className="text-sm font-semibold">
          De
          <input type="date" name="de" defaultValue={from ?? d.period.from.slice(0, 10)} className="mt-1 block h-10 rounded-(--radius-control) border border-border bg-surface px-2" />
        </label>
        <label className="text-sm font-semibold">
          Até
          <input type="date" name="ate" defaultValue={to ?? ''} className="mt-1 block h-10 rounded-(--radius-control) border border-border bg-surface px-2" />
        </label>
        <button type="submit" className={buttonVariants({ variant: 'outline' })}>Aplicar período</button>
      </form>

      <div className="space-y-2">
        {failures > 0 ? (
          <Notice tone="danger" title={`${failures} pendência(s) que precisam de ação`}>
            <Link href="/hub/financeiro/conciliacao" className="font-semibold underline">Abrir a conciliação</Link>
          </Notice>
        ) : null}
        {d.disputes_open > 0 ? (
          <Notice tone="warning" title={`${d.disputes_open} disputa(s) aberta(s)`}><Link href="/hub/financeiro/disputas" className="font-semibold underline">Analisar</Link></Notice>
        ) : null}
        {d.accounts_pending > 0 ? (
          <Notice tone="warning" title={`${d.accounts_pending} conta(s) Pix para conferir`}><Link href="/hub/financeiro/contas" className="font-semibold underline">Conferir</Link></Notice>
        ) : null}
      </div>

      <SectionTitle>No período</SectionTitle>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="Volume transacionado" value={formatMoney(d.volume)} hint={`${d.payments_count} pagamento(s)`} />
        <Stat label="Receita de comissões e taxas" value={formatMoney(d.revenue)} tone="success" />
        <Stat label="Receita líquida" value={formatMoney(d.net_revenue)} hint={`Tarifas ${formatMoney(d.fees)} · descontos ${formatMoney(d.subsidy)}`} />
        <Stat label="Estornado" value={formatMoney(d.refunded)} />
        <Stat label="Repassado" value={formatMoney(d.payouts.completed_period)} hint={`${d.payouts.completed_period_count} repasse(s)`} />
        <Stat label="Ticket médio" value={d.kpis.avg_ticket === null ? '—' : formatMoney(d.kpis.avg_ticket)} />
        <Stat label="Take rate" value={pct(d.kpis.take_rate)} hint="Receita ÷ volume" />
        <Stat label="Conversão em pagamento" value={pct(d.kpis.conversion)} hint={`Estorno: ${pct(d.kpis.refund_rate)}`} />
      </div>

      <SectionTitle>Volume confirmado por dia</SectionTitle>
      <Panel><DailyChart data={d.daily} /></Panel>

      <SectionTitle>Saldos agora</SectionTitle>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="A repassar aos prestadores" value={formatMoney(d.balances.provider_payable)} tone={d.balances.provider_payable > 0 ? 'warning' : undefined}
          hint={`${d.payouts.scheduled_count} agendado(s) · ${d.payouts.on_hold_count} retido(s)`} />
        <Stat label="Recebido e ainda não concluído" value={formatMoney(d.balances.customer_funds_held)} hint="Pedidos pagos sem conclusão confirmada" />
        <Stat label="Saldo esperado no provedor" value={formatMoney(d.balances.cash_gateway)} hint={balance === null ? 'Provedor não consultado' : `Provedor informa ${formatMoney(balance)}`} />
        <Stat label="A receber de prestadores" value={formatMoney(d.balances.provider_receivable)} hint="Estornos após o repasse" tone={d.balances.provider_receivable > 0 ? 'danger' : undefined} />
      </div>
      {balance !== null && Math.abs(balance - d.balances.cash_gateway) >= 0.01 ? (
        <p className="mt-2 text-sm text-muted-foreground">
          Diferença de {formatMoney(balance - d.balances.cash_gateway)} entre o provedor e o razão: pode ser saldo anterior, saques ou movimentos fora do aplicativo. Confira na conciliação.
        </p>
      ) : null}
      {d.payouts.avg_days_to_payout !== null ? <p className="mt-2 text-sm text-muted-foreground">Tempo médio da conclusão confirmada ao repasse: {d.payouts.avg_days_to_payout} dias.</p> : null}

      <SectionTitle>Por categoria de serviço</SectionTitle>
      <Panel>
        <Table>
          <thead><tr><th>Categoria</th><th className="text-right">Pedidos</th><th className="text-right">Volume</th><th className="text-right">Receita</th></tr></thead>
          <tbody>
            {d.by_category.length === 0 ? <tr><td colSpan={4} className="text-muted-foreground">Sem dados no período.</td></tr> : d.by_category.map((c) => (
              <tr key={c.name}><td>{c.name}</td><td className="text-right tabular-nums">{c.count}</td><td className="text-right tabular-nums">{formatMoney(c.volume)}</td><td className="text-right tabular-nums">{formatMoney(c.revenue)}</td></tr>
            ))}
          </tbody>
        </Table>
      </Panel>

      <SectionTitle>Por prestador</SectionTitle>
      <Panel>
        <Table>
          <thead><tr><th>Prestador</th><th className="text-right">Repasses</th><th className="text-right">Total</th><th className="text-right">Pago</th><th className="text-right">Pendente</th></tr></thead>
          <tbody>
            {d.by_provider.length === 0 ? <tr><td colSpan={5} className="text-muted-foreground">Sem repasses no período.</td></tr> : d.by_provider.map((p) => (
              <tr key={p.provider_id}>
                <td><Link href={`/hub/financeiro/repasses?prestador=${p.provider_id}`} className="underline">{p.name}</Link></td>
                <td className="text-right tabular-nums">{p.jobs}</td><td className="text-right tabular-nums">{formatMoney(p.earned)}</td>
                <td className="text-right tabular-nums">{formatMoney(p.paid)}</td><td className="text-right tabular-nums">{formatMoney(p.pending)}</td>
              </tr>
            ))}
          </tbody>
        </Table>
      </Panel>
    </>
  )
}
