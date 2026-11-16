import type { Metadata } from 'next'
import Link from 'next/link'
import { ChevronRight, Clock } from 'lucide-react'
import { AutoRefresh } from '@/components/app/auto-refresh'
import { SectionTitle } from '@/components/app/bits'
import { Notice } from '@/components/ui/primitives'
import { RequestCard } from '@/features/requests/components'
import { requireRole } from '@/lib/auth/session'
import { formatMoney } from '@/lib/format'
import { rpc } from '@/lib/rpc'
import type { Service, ServiceRequest } from '@/lib/types'

export const metadata: Metadata = { title: 'Início' }

export default async function CustomerHome() {
  const session = await requireRole('customer')
  const [services, requests] = await Promise.all([rpc<Service[]>('list_services'), rpc<ServiceRequest[]>('my_requests')])
  const open = requests.filter((r) => !['completed', 'cancelled'].includes(r.status))
  const toPay = requests.filter((r) => r.status === 'awaiting_payment')
  const toConfirm = requests.filter((r) => r.status === 'completed' && r.financial_status === 'service_completed')
  return (
    <>
      {open.length > 0 ? <AutoRefresh seconds={10} /> : null}
      <h1 className="text-2xl font-semibold">Olá, {session.profile.full_name.split(' ')[0]}</h1>
      <p className="mt-1 text-muted-foreground">Do que o seu carro precisa hoje?</p>

      {toPay.map((request) => (
        <Notice key={request.id} tone="warning" title="Falta o pagamento" className="mt-4">
          {request.service.name}: pague {formatMoney(request.total)} por Pix para chamarmos um prestador.{' '}
          <Link href={`/cliente/pedidos/${request.id}`} className="font-semibold underline">Pagar agora</Link>
        </Notice>
      ))}
      {toConfirm.map((request) => (
        <Notice key={request.id} tone="info" title="Confirme o serviço" className="mt-4">
          {request.service.name}: o prestador concluiu. Confirme ou conte se houve problema.{' '}
          <Link href={`/cliente/pedidos/${request.id}`} className="font-semibold underline">Ver pedido</Link>
        </Notice>
      ))}

      {open.length > 0 ? (
        <>
          <SectionTitle>Em andamento</SectionTitle>
          <div className="space-y-2">
            {open.map((request) => (
              <RequestCard key={request.id} request={request} href={`/cliente/pedidos/${request.id}`} amount={request.total} />
            ))}
          </div>
        </>
      ) : null}

      <SectionTitle>Serviços</SectionTitle>
      <ul className="space-y-2">
        {services.map((service) => (
          <li key={service.id}>
            <Link href={`/cliente/pedir/${service.id}`} className="flex items-center gap-3 rounded-(--radius-panel) border border-border bg-surface px-4 py-4 hover:border-foreground/30">
              <div className="min-w-0 flex-1">
                <p className="font-semibold">{service.name}</p>
                <p className="mt-0.5 text-sm text-muted-foreground">{service.description}</p>
                <p className="mt-1.5 flex items-center gap-1 text-sm text-muted-foreground">
                  <Clock className="size-3.5" aria-hidden="true" /> cerca de {service.est_minutes} min
                </p>
              </div>
              <p className="font-display text-lg font-semibold tabular-nums">{formatMoney(service.base_price)}</p>
              <ChevronRight className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
            </Link>
          </li>
        ))}
      </ul>
    </>
  )
}
