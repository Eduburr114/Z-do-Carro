import type { Metadata } from 'next'
import { AutoRefresh } from '@/components/app/auto-refresh'
import { Badge, Empty, Panel } from '@/components/ui/primitives'
import { StatusBadge } from '@/features/requests/components'
import { requireStaff } from '@/lib/auth/session'
import { financialStatus, formatDateTime, formatMoney } from '@/lib/format'
import { rpc } from '@/lib/rpc'
import type { ServiceRequest } from '@/lib/types'

export const metadata: Metadata = { title: 'Pedidos' }

export default async function HubRequestsPage() {
  await requireStaff('admin')
  const requests = await rpc<ServiceRequest[]>('admin_requests')
  return (
    <>
      <AutoRefresh seconds={15} />
      <h1 className="mb-4 text-2xl font-semibold">Pedidos</h1>
      <Panel>
        {requests.length === 0 ? (
          <Empty title="Nenhum pedido ainda" />
        ) : (
          <ul className="divide-y divide-border">
            {requests.map((r) => (
              <li key={r.id} className="px-4 py-3.5 sm:px-5">
                <div className="flex flex-wrap items-center gap-2">
                  <p className="font-semibold">nº {r.number} · {r.service.name}</p>
                  <StatusBadge status={r.status} />
                  <Badge tone={financialStatus[r.financial_status].tone}>{financialStatus[r.financial_status].label}</Badge>
                </div>
                <p className="mt-0.5 text-sm text-muted-foreground">
                  {formatDateTime(r.created_at)} · cliente {r.customer?.name ?? '—'} · prestador {r.provider?.name ?? 'não definido'}
                </p>
                <p className="text-sm text-muted-foreground">{r.address}</p>
                <p className="mt-1 text-sm tabular-nums">
                  Total {formatMoney(r.total)} · comissão {formatMoney(r.commission_amount)} · líquido do prestador {formatMoney(r.provider_net)}
                  {Number(r.discount_amount) > 0 ? ` · desconto ${formatMoney(r.discount_amount)}` : ''}
                </p>
                {r.cancel_reason ? <p className="text-sm text-muted-foreground">Motivo do cancelamento: {r.cancel_reason}</p> : null}
              </li>
            ))}
          </ul>
        )}
      </Panel>
    </>
  )
}
