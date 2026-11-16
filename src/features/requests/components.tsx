import Link from 'next/link'
import { Check, ChevronRight } from 'lucide-react'
import { Badge, Panel } from '@/components/ui/primitives'
import { Row } from '@/components/app/bits'
import { eventLabel, formatDateTime, formatMoney, formatPercent, formatTime, requestStatus } from '@/lib/format'
import type { RequestStatus, ServiceRequest } from '@/lib/types'

export function StatusBadge({ status }: { status: RequestStatus }) {
  const info = requestStatus[status]
  return <Badge tone={info.tone}>{info.label}</Badge>
}

/** Cartão de pedido nas listas. `amount` muda conforme quem vê (total ou líquido). */
export function RequestCard({ request, href, amount, subtitle }: { request: ServiceRequest; href: string; amount: number; subtitle?: string }) {
  return (
    <Link href={href} className="flex items-center gap-3 rounded-(--radius-panel) border border-border bg-surface px-4 py-3.5 hover:border-foreground/30">
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <p className="font-semibold">{request.service.name}</p>
          <StatusBadge status={request.status} />
        </div>
        <p className="mt-0.5 truncate text-sm text-muted-foreground">
          {subtitle ?? `${request.vehicle.brand} ${request.vehicle.model} · ${formatDateTime(request.created_at)}`}
        </p>
      </div>
      <p className="font-semibold tabular-nums">{formatMoney(amount)}</p>
      <ChevronRight className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
    </Link>
  )
}

const order: RequestStatus[] = ['searching', 'accepted', 'en_route', 'in_progress', 'completed']
const stepLabels = ['Buscando', 'Confirmado', 'A caminho', 'Em serviço', 'Concluído']

/** Trilha das etapas do atendimento. */
export function StatusSteps({ status }: { status: RequestStatus }) {
  if (status === 'cancelled') return null
  const current = order.indexOf(status)
  return (
    <ol className="flex" aria-label="Etapas do atendimento">
      {stepLabels.map((label, index) => {
        const done = index < current || status === 'completed'
        const active = index === current && status !== 'completed'
        return (
          <li key={label} className="relative flex flex-1 flex-col items-center gap-1.5 text-center" aria-current={active ? 'step' : undefined}>
            {index > 0 ? <span className={`absolute top-3.5 right-1/2 h-0.5 w-full -translate-y-1/2 ${index <= current ? 'bg-foreground' : 'bg-border'}`} /> : null}
            <span
              className={`relative z-10 flex size-7 items-center justify-center rounded-full text-xs font-bold ${
                done ? 'bg-foreground text-background' : active ? 'bg-brand text-brand-foreground ring-4 ring-brand/30' : 'bg-surface-2 text-muted-foreground'
              }`}
            >
              {done ? <Check className="size-4" aria-hidden="true" /> : index + 1}
            </span>
            <span className={`text-[0.7rem] leading-tight font-semibold ${done || active ? '' : 'text-muted-foreground'}`}>{label}</span>
          </li>
        )
      })}
    </ol>
  )
}

/**
 * Resumo de valores. O cliente vê preço, desconto, taxa e total; o prestador vê
 * a base de cálculo, a comissão e o líquido (cláusula 7.3). O desconto é
 * custeado pela plataforma e não reduz o líquido do prestador.
 */
export function PriceSummary({ request, view }: { request: ServiceRequest; view: 'customer' | 'provider' | 'hub' }) {
  const approved = request.extras.filter((extra) => extra.status === 'approved')
  const base = Number(request.price) + Number(request.extras_total)
  return (
    <Panel className="px-4 py-3">
      <Row label={request.service.name} value={formatMoney(request.price)} />
      {approved.map((extra) => (
        <Row key={extra.id} label={`Adicional: ${extra.description}`} value={formatMoney(extra.price)} />
      ))}
      {view !== 'provider' && Number(request.discount_amount) > 0 ? (
        <Row label={`Desconto${request.promotion_name ? ` (${request.promotion_name})` : ''}`} value={`− ${formatMoney(request.discount_amount)}`} />
      ) : null}
      {view !== 'provider' && Number(request.fee_amount) > 0 ? <Row label="Taxa da plataforma" value={formatMoney(request.fee_amount)} /> : null}
      <div className="my-1.5 border-t border-border" />
      {view === 'provider' ? <Row label="Valor do serviço" value={formatMoney(base)} /> : <Row label={view === 'customer' ? 'Total' : 'Total pago pelo cliente'} value={formatMoney(request.total)} strong={view === 'customer'} />}
      {view !== 'customer' ? (
        <>
          <Row label={`Comissão da HUB (${formatPercent(request.commission_percent)})`} value={`− ${formatMoney(request.commission_amount)}`} />
          <Row label={view === 'provider' ? 'Você recebe' : 'Líquido do prestador'} value={formatMoney(request.provider_net)} strong />
        </>
      ) : null}
    </Panel>
  )
}

export function Timeline({ events }: { events: ServiceRequest['events'] }) {
  return (
    <ol className="space-y-3">
      {events.map((event, index) => (
        <li key={index} className="flex gap-3 text-sm">
          <span className="w-12 shrink-0 text-muted-foreground tabular-nums">{formatTime(event.at)}</span>
          <span>
            <span className="font-medium">{eventLabel[event.kind] ?? event.kind}</span>
            {event.note ? <span className="block text-muted-foreground">{event.note}</span> : null}
          </span>
        </li>
      ))}
    </ol>
  )
}
