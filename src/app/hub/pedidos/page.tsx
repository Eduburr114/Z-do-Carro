import type { Metadata } from 'next'
import { AutoRefresh } from '@/components/app/auto-refresh'
import { ActionForm, SubmitButton } from '@/components/ui/form'
import { confirmPayment, markPayout } from '@/features/hub/actions'
import { Badge, Empty, Panel } from '@/components/ui/primitives'
import { StatusBadge } from '@/features/requests/components'
import { requireRole } from '@/lib/auth/session'
import { formatDate, formatDateTime, formatMoney } from '@/lib/format'
import { rpc } from '@/lib/rpc'
import type { ServiceRequest } from '@/lib/types'

export const metadata: Metadata = { title: 'Pedidos' }

export default async function HubRequestsPage() {
  await requireRole('hub_admin')
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
                  {r.status === 'completed' ? (
                    <Badge tone={r.payment_status === 'paid' ? 'success' : 'warning'}>
                      {r.payment_status === 'paid' ? 'Pago' : r.payment_claimed_at ? 'Pix informado, a confirmar' : 'Aguardando pagamento'}
                    </Badge>
                  ) : null}
                  {r.payout_status === 'paid' ? <Badge tone="success">Repassado</Badge> : null}
                </div>
                <p className="mt-0.5 text-sm text-muted-foreground">
                  {formatDateTime(r.created_at)} · cliente {r.customer?.name ?? '—'} · prestador {r.provider?.name ?? 'não definido'}
                </p>
                <p className="text-sm text-muted-foreground">{r.address}</p>
                <p className="mt-1 text-sm tabular-nums">
                  Total {formatMoney(r.total)} · comissão {formatMoney(r.commission_amount)} · líquido do prestador {formatMoney(r.provider_net)}
                </p>
                {r.cancel_reason ? <p className="text-sm text-muted-foreground">Motivo do cancelamento: {r.cancel_reason}</p> : null}
                {r.status === 'completed' && r.payment_status === 'pending' ? (
                  <ActionForm action={confirmPayment} successMessage="Pagamento confirmado." className="mt-2">
                    <input type="hidden" name="id" value={r.id} />
                    <SubmitButton size="sm" variant={r.payment_claimed_at ? 'primary' : 'secondary'}>
                      Confirmar recebimento de {formatMoney(r.total)}
                    </SubmitButton>
                  </ActionForm>
                ) : null}
                {r.payout_status === 'pending' ? (
                  <ActionForm action={markPayout} successMessage="Repasse registrado." className="mt-2">
                    <input type="hidden" name="id" value={r.id} />
                    <SubmitButton size="sm" variant="secondary">
                      Registrar repasse de {formatMoney(r.provider_net)} (previsto até {formatDate(r.payout_due)})
                    </SubmitButton>
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
