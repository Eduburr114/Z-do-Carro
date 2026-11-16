import type { Metadata } from 'next'
import { notFound } from 'next/navigation'
import { MapPin, Phone } from 'lucide-react'
import { AutoRefresh } from '@/components/app/auto-refresh'
import { SectionTitle } from '@/components/app/bits'
import { buttonVariants } from '@/components/ui/button'
import { ActionForm, Field, MoneyField, SubmitButton, TextareaField } from '@/components/ui/form'
import { Badge, Notice, Panel } from '@/components/ui/primitives'
import { acceptRequest, advanceRequest, declineRequest, proposeExtra, withdrawRequest } from '@/features/provider/actions'
import { PositionBeacon } from '@/features/provider/online-toggle'
import { PriceSummary, StatusBadge, StatusSteps, Timeline } from '@/features/requests/components'
import { requireRole } from '@/lib/auth/session'
import { formatDate, formatKm, formatMoney, formatPhone } from '@/lib/format'
import { AppError, rpc } from '@/lib/rpc'
import type { ServiceRequest } from '@/lib/types'

export const metadata: Metadata = { title: 'Atendimento' }

const next = {
  accepted: { to: 'en_route', label: 'Estou a caminho' },
  en_route: { to: 'in_progress', label: 'Cheguei, iniciar serviço' },
  in_progress: { to: 'completed', label: 'Concluir serviço' },
} as const

const extraTone = { proposed: 'warning', approved: 'success', rejected: 'neutral' } as const
const extraLabel = { proposed: 'Aguardando o cliente', approved: 'Aprovado', rejected: 'Recusado' } as const

export default async function JobPage({ params }: { params: Promise<{ id: string }> }) {
  await requireRole('provider')
  const { id } = await params
  const request = await rpc<ServiceRequest>('request_detail', { p_id: id }).catch((error) => {
    if (error instanceof AppError) notFound()
    throw error
  })
  const offer = request.customer === null
  const live = ['accepted', 'en_route', 'in_progress'].includes(request.status)
  const step = live ? next[request.status as keyof typeof next] : null
  const mapsUrl = request.lat !== null && request.lng !== null
    ? `https://www.google.com/maps/dir/?api=1&destination=${request.lat},${request.lng}`
    : `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(request.address)}`

  return (
    <>
      {live || offer ? <AutoRefresh seconds={8} /> : null}
      {live ? <PositionBeacon /> : null}
      <div className="flex items-center justify-between gap-3">
        <p className="text-sm text-muted-foreground">Pedido nº {request.number}</p>
        <StatusBadge status={request.status} />
      </div>
      <h1 className="mt-1 text-2xl font-semibold">{request.service.name}</h1>
      <p className="mt-1 text-muted-foreground">
        {request.vehicle.brand} {request.vehicle.model}{request.vehicle.year ? ` ${request.vehicle.year}` : ''}
        {request.vehicle.plate ? ` · ${request.vehicle.plate}` : ''}
      </p>

      {!offer && request.status !== 'cancelled' ? <div className="mt-6"><StatusSteps status={request.status} /></div> : null}

      <Panel className="mt-5 px-4 py-3.5">
        <p className="flex items-start gap-1.5">
          <MapPin className="mt-0.5 size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
          <span>{request.address}{request.distance_km !== null ? ` · ${formatKm(request.distance_km)}` : ''}</span>
        </p>
        {request.notes ? <p className="mt-2 text-sm text-muted-foreground">Observações do cliente: {request.notes}</p> : null}
        {live ? (
          <div className="mt-3 grid grid-cols-2 gap-2">
            <a href={mapsUrl} target="_blank" rel="noreferrer" className={buttonVariants({ variant: 'outline' })}><MapPin /> Abrir rota</a>
            <a href={`tel:+55${request.customer!.phone}`} className={buttonVariants({ variant: 'outline' })} aria-label={`Ligar para ${request.customer!.name}: ${formatPhone(request.customer!.phone)}`}>
              <Phone /> Ligar
            </a>
          </div>
        ) : null}
        {request.customer ? <p className="mt-3 text-sm">Cliente: <span className="font-semibold">{request.customer.name}</span></p> : null}
      </Panel>

      {offer ? (
        <>
          <Notice tone="info" className="mt-4">Nome, telefone e placa do cliente aparecem depois do aceite. Recusar não afeta a sua nota.</Notice>
          <div className="mt-4 grid grid-cols-2 gap-2">
            <ActionForm action={declineRequest}>
              <input type="hidden" name="id" value={request.id} />
              <SubmitButton variant="outline" size="lg" className="w-full">Recusar</SubmitButton>
            </ActionForm>
            <ActionForm action={acceptRequest}>
              <input type="hidden" name="id" value={request.id} />
              <SubmitButton size="lg" className="w-full">Aceitar</SubmitButton>
            </ActionForm>
          </div>
        </>
      ) : null}

      {step ? (
        <ActionForm action={advanceRequest} className="mt-4">
          <input type="hidden" name="id" value={request.id} />
          <input type="hidden" name="to" value={step.to} />
          <SubmitButton size="lg" className="w-full">{step.label}</SubmitButton>
        </ActionForm>
      ) : null}

      {request.status === 'completed' ? (
        <Notice tone={request.payout_status === 'paid' ? 'success' : 'info'} className="mt-4">
          {request.payout_status === 'paid'
            ? `Repasse de ${formatMoney(request.provider_net)} realizado.`
            : request.payout_status === 'pending'
              ? `Cliente pagou. Repasse de ${formatMoney(request.provider_net)} previsto até ${formatDate(request.payout_due)}.`
              : 'Aguardando o pagamento do cliente para liberar o repasse.'}
        </Notice>
      ) : null}

      <SectionTitle>Valores</SectionTitle>
      <PriceSummary request={request} view="provider" />

      {!offer && (request.extras.length > 0 || request.status === 'in_progress') ? (
        <>
          <SectionTitle>Serviços adicionais</SectionTitle>
          {request.extras.length > 0 ? (
            <Panel className="mb-3">
              <ul className="divide-y divide-border">
                {request.extras.map((extra) => (
                  <li key={extra.id} className="flex items-center justify-between gap-3 px-4 py-3">
                    <div className="min-w-0">
                      <p className="font-medium">{extra.description}</p>
                      <p className="text-sm text-muted-foreground tabular-nums">{formatMoney(extra.price)}</p>
                    </div>
                    <Badge tone={extraTone[extra.status]}>{extraLabel[extra.status]}</Badge>
                  </li>
                ))}
              </ul>
            </Panel>
          ) : null}
          {request.status === 'in_progress' ? (
            <ActionForm action={proposeExtra} successMessage="Orçamento enviado ao cliente.">
              <input type="hidden" name="id" value={request.id} />
              <Field label="O que mais precisa ser feito?" name="description" placeholder="Ex.: troca da válvula" />
              <MoneyField label="Valor ao cliente (R$)" name="price" />
              <SubmitButton variant="secondary" className="w-full">Enviar orçamento ao cliente</SubmitButton>
              <p className="text-sm text-muted-foreground">Execute o adicional somente depois que o cliente aprovar no aplicativo.</p>
            </ActionForm>
          ) : null}
        </>
      ) : null}

      {!offer ? (
        <>
          <SectionTitle>Histórico</SectionTitle>
          <Timeline events={request.events} />
        </>
      ) : null}

      {['accepted', 'en_route'].includes(request.status) ? (
        <details className="mt-8 rounded-(--radius-panel) border border-border bg-surface px-4 py-3">
          <summary className="cursor-pointer font-semibold">Não vou conseguir atender</summary>
          <ActionForm action={withdrawRequest} className="mt-3">
            <input type="hidden" name="id" value={request.id} />
            <TextareaField label="Motivo" name="reason" hint="O cliente é avisado e o pedido volta para outros prestadores." />
            <SubmitButton variant="outline" className="w-full">Desistir deste atendimento</SubmitButton>
          </ActionForm>
        </details>
      ) : null}
    </>
  )
}
