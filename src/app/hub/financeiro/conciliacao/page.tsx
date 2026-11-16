import type { Metadata } from 'next'
import { SectionTitle } from '@/components/app/bits'
import { ActionForm, Field, MoneyField, SubmitButton } from '@/components/ui/form'
import { Empty, Notice, PageHeader, Panel, Table } from '@/components/ui/primitives'
import { authorizeWithdrawal } from '@/features/finance/actions'
import { FinanceTabs } from '@/features/hub/tabs'
import { requireStaff } from '@/lib/auth/session'
import { formatDateTime, formatMoney } from '@/lib/format'
import { rpc } from '@/lib/rpc'

export const metadata: Metadata = { title: 'Conciliação' }

type Reconciliation = {
  trial_balance: number
  accounts: { account: string; debits: number; credits: number; balance: number }[]
  issues: { kind: string; ref: string; number: number | null; detail: string; at: string }[]
}
type Audit = { id: number; at: string; actor: string | null; actor_role: string; action: string; entity: string; entity_id: string; note: string | null }

const accountLabel: Record<string, string> = {
  cash_gateway: 'Saldo no provedor', customer_funds_held: 'Recebido de clientes (não reconhecido)', provider_payable: 'A repassar a prestadores',
  provider_receivable: 'A receber de prestadores', platform_revenue: 'Receita da plataforma', gateway_fees: 'Tarifas do provedor', promotion_subsidy: 'Descontos custeados',
}
const issueLink: Record<string, string> = {
  payment_stale: '/hub/financeiro/pagamentos?status=pending', payment_failed: '/hub/financeiro/pagamentos?status=failed', remote_cancel: '/hub/financeiro/pagamentos',
  payout_uncertain: '/hub/financeiro/repasses?status=processing', payout_stuck: '/hub/financeiro/repasses?status=processing',
  payout_failed: '/hub/financeiro/repasses?status=failed', refund_failed: '/hub/financeiro/pagamentos?status=refund_pending',
  refund_manual: '/hub/financeiro/pagamentos?status=refund_pending',
}

export default async function ReconciliationPage() {
  await requireStaff('finance')
  const [r, audit] = await Promise.all([rpc<Reconciliation>('finance_reconciliation'), rpc<Audit[]>('finance_audit', { p_limit: 60 })])
  return (
    <>
      <PageHeader title="Financeiro" />
      <FinanceTabs current="/hub/financeiro/conciliacao" />

      {Number(r.trial_balance) === 0
        ? <Notice tone="success" title="Razão fechado">Débitos e créditos conferem.</Notice>
        : <Notice tone="danger" title="Razão desbalanceado">Diferença de {Number(r.trial_balance)} centavos. Acione o responsável técnico.</Notice>}

      <SectionTitle>Pendências</SectionTitle>
      <Panel>
        {r.issues.length === 0 ? <Empty title="Nada a conciliar" /> : (
          <ul className="divide-y divide-border">
            {r.issues.map((i) => (
              <li key={`${i.kind}-${i.ref}`} className="px-4 py-3 text-sm">
                <a href={issueLink[i.kind] ?? '/hub/financeiro'} className="font-semibold underline">{i.number ? `Pedido nº ${i.number}` : i.kind}</a>
                <span className="text-muted-foreground"> · {formatDateTime(i.at)}</span>
                <p>{i.detail}</p>
              </li>
            ))}
          </ul>
        )}
      </Panel>

      <SectionTitle>Balancete do razão</SectionTitle>
      <Panel>
        <Table>
          <thead><tr><th>Conta</th><th className="text-right">Débitos</th><th className="text-right">Créditos</th><th className="text-right">Saldo (D − C)</th></tr></thead>
          <tbody>
            {r.accounts.map((a) => (
              <tr key={a.account}><td>{accountLabel[a.account] ?? a.account}</td><td className="text-right tabular-nums">{formatMoney(a.debits)}</td>
                <td className="text-right tabular-nums">{formatMoney(a.credits)}</td><td className="text-right tabular-nums">{formatMoney(a.balance)}</td></tr>
            ))}
          </tbody>
        </Table>
      </Panel>

      <SectionTitle>Saque da HUB</SectionTitle>
      <Panel className="px-4 py-4">
        <p className="mb-3 text-sm text-muted-foreground">
          Com a validação de saque ligada no Asaas, toda transferência que não é repasse é recusada. Para retirar a receita, autorize aqui o valor exato e faça o saque no painel do Asaas em até 30 minutos.
        </p>
        <ActionForm action={authorizeWithdrawal} successMessage="Saque autorizado por 30 minutos." className="max-w-md">
          <MoneyField label="Valor exato do saque (R$)" name="amount" />
          <Field label="Finalidade" name="note" placeholder="ex.: retirada de receita de novembro" />
          <SubmitButton variant="secondary">Autorizar saque</SubmitButton>
        </ActionForm>
      </Panel>

      <SectionTitle>Auditoria recente</SectionTitle>
      <Panel>
        <Table>
          <thead><tr><th>Quando</th><th>Quem</th><th>Ação</th><th>Registro</th></tr></thead>
          <tbody>
            {audit.map((a) => (
              <tr key={a.id}>
                <td className="whitespace-nowrap">{formatDateTime(a.at)}</td>
                <td>{a.actor ?? (a.actor_role === 'service_role' ? 'sistema' : a.actor_role)}</td>
                <td>{a.action}{a.note ? ` — ${a.note}` : ''}</td>
                <td className="font-mono text-xs">{a.entity}/{a.entity_id?.slice(0, 8)}</td>
              </tr>
            ))}
          </tbody>
        </Table>
      </Panel>
    </>
  )
}
