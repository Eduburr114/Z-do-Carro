import type { Metadata } from 'next'
import { SectionTitle } from '@/components/app/bits'
import { Empty, Panel, Stat } from '@/components/ui/primitives'
import { RequestCard } from '@/features/requests/components'
import { requireRole } from '@/lib/auth/session'
import { formatDate, formatMoney } from '@/lib/format'
import { rpc } from '@/lib/rpc'
import type { ServiceRequest } from '@/lib/types'

export const metadata: Metadata = { title: 'Ganhos' }

type Jobs = { summary: { completed: number; net_total: number; to_receive: number; received: number; awaiting_payment: number }; jobs: ServiceRequest[] }

const payoutText = (job: ServiceRequest) =>
  job.status !== 'completed'
    ? undefined
    : job.payout_status === 'paid'
      ? 'Repasse recebido'
      : job.payout_status === 'pending'
        ? `Repasse previsto até ${formatDate(job.payout_due)}`
        : 'Aguardando pagamento do cliente'

export default async function EarningsPage() {
  await requireRole('provider')
  const { summary, jobs } = await rpc<Jobs>('provider_jobs')
  return (
    <>
      <h1 className="mb-4 text-2xl font-semibold">Ganhos</h1>
      <div className="grid grid-cols-2 gap-3">
        <Stat label="A receber" value={formatMoney(summary.to_receive)} hint="Pagos pelo cliente, aguardando repasse" />
        <Stat label="Recebido" value={formatMoney(summary.received)} tone="success" />
        <Stat label="Aguardando cliente" value={formatMoney(summary.awaiting_payment)} />
        <Stat label="Atendimentos concluídos" value={summary.completed} />
      </div>
      <p className="mt-3 text-sm text-muted-foreground">Valores líquidos, já sem a comissão da HUB. Não há meta nem faturamento mínimo.</p>

      <SectionTitle>Atendimentos</SectionTitle>
      {jobs.length === 0 ? (
        <Panel><Empty title="Nenhum atendimento ainda" /></Panel>
      ) : (
        <div className="space-y-2">
          {jobs.map((job) => (
            <RequestCard key={job.id} request={job} href={`/prestador/pedidos/${job.id}`} amount={job.provider_net} subtitle={payoutText(job)} />
          ))}
        </div>
      )}
    </>
  )
}
