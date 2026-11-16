import type { Metadata } from 'next'
import { notFound } from 'next/navigation'
import { Phone } from 'lucide-react'
import { AutoRefresh } from '@/components/app/auto-refresh'
import { RatingBadge, SectionTitle } from '@/components/app/bits'
import { buttonVariants } from '@/components/ui/button'
import { ActionForm, SubmitButton, TextareaField } from '@/components/ui/form'
import { Notice, Panel } from '@/components/ui/primitives'
import { cancelRequest, confirmCompletion, decideExtra, openDispute, reviewRequest } from '@/features/customer/actions'
import { PaymentPanel } from '@/features/payments/payment-panel'
import { LiveMap, type MapPoint } from '@/features/map/live-map'
import { PriceSummary, StatusBadge, StatusSteps, Timeline } from '@/features/requests/components'
import { requireRole } from '@/lib/auth/session'
import { formatDateTime, formatKm, formatMoney, formatPhone } from '@/lib/format'
import { AppError, rpc } from '@/lib/rpc'
import type { PaymentInfo, ServiceRequest } from '@/lib/types'

export const metadata: Metadata = { title: 'Pedido' }

const headline: Record<ServiceRequest['status'], string> = {
  awaiting_payment: 'Falta só o pagamento',
  searching: 'Procurando um prestador perto de você',
  accepted: 'Prestador confirmado',
  en_route: 'O prestador está a caminho',
  in_progress: 'Serviço em andamento',
  completed: 'Serviço concluído',
  cancelled: 'Pedido cancelado',
}

export default async function RequestPage({ params }: { params: Promise<{ id: string }> }) {
  await requireRole('customer')
  const { id } = await params
  const request = await rpc<ServiceRequest>('request_detail', { p_id: id }).catch((error) => {
    if (error instanceof AppError) notFound()
    throw error
  })
  const live = !['completed', 'cancelled', 'awaiting_payment'].includes(request.status)
  const proposed = request.extras.filter((extra) => extra.status === 'proposed')
  const unpaidExtras = request.extras.filter((extra) => extra.status === 'approved' && !extra.paid)
  const canCancel = ['awaiting_payment', 'searching', 'accepted', 'en_route'].includes(request.status)
  const mustPay = request.status === 'awaiting_payment' || unpaidExtras.length > 0
  const payment = mustPay ? await rpc<PaymentInfo>('payment_info') : null
  const toConfirm = request.status === 'completed' && request.financial_status === 'service_completed'
  const paidBeforeCancel = request.status === 'cancelled' && ['refund_pending', 'refunded'].includes(request.financial_status)
  const points: MapPoint[] = []
  if (live && request.lat !== null && request.lng !== null) {
    points.push({ lat: request.lat, lng: request.lng, label: 'Seu carro', kind: 'car' })
    if (request.provider?.lat != null && request.provider.lng != null && request.status !== 'in_progress') {
      points.push({ lat: request.provider.lat, lng: request.provider.lng, label: 'Prestador', kind: 'provider' })
    }
  }

  return (
    <>
      {/* Também enquanto o pagamento aguarda confirmação: a tela muda quando o banco confirma o Pix. */}
      {live || mustPay || request.financial_status === 'refund_pending' ? <AutoRefresh seconds={mustPay ? 4 : 6} /> : null}
      <div className="flex items-center justify-between gap-3">
        <p className="text-sm text-muted-foreground">Pedido nº {request.number}</p>
        <StatusBadge status={request.status} />
      </div>
      <h1 className="mt-1 text-2xl font-semibold text-balance">{headline[request.status]}</h1>
      <p className="mt-1 text-muted-foreground">
        {request.service.name} · {request.vehicle.brand} {request.vehicle.model} ({request.vehicle.plate})
      </p>

      {request.status !== 'cancelled' && request.status !== 'awaiting_payment' ? <div className="mt-6"><StatusSteps status={request.status} /></div> : null}

      {request.status === 'awaiting_payment' && payment ? <PaymentPanel request={request} info={payment} /> : null}
      {payment ? unpaidExtras.map((extra) => <PaymentPanel key={extra.id} request={request} info={payment} extra={extra} />) : null}

      {points.length > 0 ? <div className="mt-5"><LiveMap points={points} /></div> : null}

      {request.status === 'searching' ? (
        <Notice tone="info" className="mt-5">Avisamos os prestadores credenciados da região. Esta tela se atualiza sozinha.</Notice>
      ) : null}

      {proposed.map((extra) => (
        <Panel key={extra.id} className="mt-5 border-2 border-brand px-4 py-4">
          <p className="text-sm font-semibold text-muted-foreground">Orçamento adicional</p>
          <p className="mt-1 text-lg font-semibold">{extra.description}</p>
          <p className="font-display text-2xl font-semibold tabular-nums">{formatMoney(extra.price)}</p>
          <p className="mt-1 text-sm text-muted-foreground">O prestador só executa este item se você aprovar.</p>
          <div className="mt-3 grid grid-cols-2 gap-2">
            <ActionForm action={decideExtra} successMessage="Adicional recusado.">
              <input type="hidden" name="id" value={extra.id} />
              <input type="hidden" name="approve" value="no" />
              <SubmitButton variant="outline" className="w-full">Recusar</SubmitButton>
            </ActionForm>
            <ActionForm action={decideExtra} successMessage="Adicional aprovado.">
              <input type="hidden" name="id" value={extra.id} />
              <input type="hidden" name="approve" value="yes" />
              <SubmitButton className="w-full">Aprovar</SubmitButton>
            </ActionForm>
          </div>
        </Panel>
      ))}

      {toConfirm ? (
        <Panel className="mt-5 border-2 border-brand px-4 py-4">
          <p className="text-lg font-semibold">O serviço ficou bom?</p>
          <p className="mt-1 text-sm text-muted-foreground">
            Confirme para liberar o repasse ao prestador. Se algo deu errado, conte para a HUB: o valor fica retido até a análise.
            {request.completion_deadline ? ` Sem resposta até ${formatDateTime(request.completion_deadline)}, o serviço é considerado confirmado.` : ''}
          </p>
          <ActionForm action={confirmCompletion} successMessage="Serviço confirmado. Obrigado!" className="mt-3">
            <input type="hidden" name="id" value={request.id} />
            <SubmitButton size="lg" className="w-full">Confirmar serviço</SubmitButton>
          </ActionForm>
          <details className="mt-3">
            <summary className="cursor-pointer text-sm font-semibold">Tive um problema com o serviço</summary>
            <ActionForm action={openDispute} successMessage="Recebemos o seu relato." className="mt-3">
              <input type="hidden" name="id" value={request.id} />
              <TextareaField label="O que aconteceu?" name="reason" hint="Ao menos 20 caracteres. A equipe da HUB analisa e responde pelo aplicativo." />
              <SubmitButton variant="outline" className="w-full">Enviar para análise</SubmitButton>
            </ActionForm>
          </details>
        </Panel>
      ) : null}

      {request.financial_status === 'disputed' ? (
        <Notice tone="warning" title="Em análise pela HUB" className="mt-5">
          Recebemos o seu relato. O valor fica retido até a decisão, que você recebe por aviso.
        </Notice>
      ) : null}
      {request.dispute && request.dispute.status !== 'open' ? (
        <Notice tone="info" title="Decisão da HUB" className="mt-5">{request.dispute.resolution_note}</Notice>
      ) : null}
      {request.financial_status === 'refund_pending' ? (
        <Notice tone="info" title="Estorno em andamento" className="mt-5">O valor pago volta para a conta de origem do Pix. Avisamos quando concluir.</Notice>
      ) : null}
      {request.financial_status === 'refunded' ? (
        <Notice tone="success" title="Estorno concluído" className="mt-5">Devolvemos o valor pago para a conta de origem do Pix.</Notice>
      ) : null}
      {request.status === 'cancelled' && !paidBeforeCancel && request.financial_status === 'cancelled' && request.cancel_reason ? (
        <Notice tone="neutral" className="mt-5">{request.cancel_reason}</Notice>
      ) : null}

      {request.status === 'completed' && !toConfirm && request.financial_status !== 'disputed' && !request.review ? (
        <Panel className="mt-5 px-4 py-4">
          <p className="text-lg font-semibold">Como foi o atendimento?</p>
          <ActionForm action={reviewRequest} successMessage="Obrigado pela avaliação!" className="mt-3">
            <input type="hidden" name="id" value={request.id} />
            <fieldset>
              <legend className="sr-only">Nota de 1 a 5</legend>
              <div className="flex gap-2">
                {[1, 2, 3, 4, 5].map((value) => (
                  <label key={value} className="flex h-12 flex-1 cursor-pointer items-center justify-center rounded-(--radius-control) border border-border bg-surface font-semibold has-checked:border-foreground has-checked:bg-brand has-checked:text-brand-foreground">
                    <input type="radio" name="rating" value={value} className="sr-only" defaultChecked={value === 5} />
                    {value}★
                  </label>
                ))}
              </div>
            </fieldset>
            <TextareaField label="Comentário" name="comment" hint="Opcional." />
            <SubmitButton className="w-full">Enviar avaliação</SubmitButton>
          </ActionForm>
        </Panel>
      ) : null}

      {request.review ? (
        <Notice tone="success" className="mt-5">Você avaliou este atendimento com {request.review.rating}★.</Notice>
      ) : null}

      {request.provider ? (
        <>
          <SectionTitle>Prestador</SectionTitle>
          <Panel className="flex items-center gap-3 px-4 py-3.5">
            <div className="min-w-0 flex-1">
              <p className="font-semibold">{request.provider.name}</p>
              <RatingBadge rating={request.provider.rating} />
              {live && request.provider.distance_km !== null ? (
                <p className="text-sm text-muted-foreground">A {formatKm(request.provider.distance_km)} de você</p>
              ) : null}
            </div>
            {live ? (
              <a href={`tel:+55${request.provider.phone}`} className={buttonVariants({ variant: 'outline' })} aria-label={`Ligar para ${request.provider.name}: ${formatPhone(request.provider.phone)}`}>
                <Phone /> Ligar
              </a>
            ) : null}
          </Panel>
        </>
      ) : null}

      <SectionTitle>Resumo</SectionTitle>
      <PriceSummary request={request} view="customer" />
      <p className="mt-2 text-sm text-muted-foreground">Local: {request.address}</p>
      {request.notes ? <p className="text-sm text-muted-foreground">Observações: {request.notes}</p> : null}

      <SectionTitle>Histórico</SectionTitle>
      <Timeline events={request.events} />

      {canCancel ? (
        <ActionForm action={cancelRequest} successMessage="Pedido cancelado." className="mt-8">
          <input type="hidden" name="id" value={request.id} />
          <SubmitButton variant="ghost" className="w-full text-danger">Cancelar pedido</SubmitButton>
        </ActionForm>
      ) : null}
    </>
  )
}
