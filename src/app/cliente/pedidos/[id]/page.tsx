import type { Metadata } from 'next'
import { notFound } from 'next/navigation'
import { Phone } from 'lucide-react'
import { AutoRefresh } from '@/components/app/auto-refresh'
import { RatingBadge, SectionTitle } from '@/components/app/bits'
import { buttonVariants } from '@/components/ui/button'
import { ActionForm, SubmitButton, TextareaField } from '@/components/ui/form'
import { Notice, Panel } from '@/components/ui/primitives'
import { cancelRequest, claimPayment, decideExtra, payRequest, reviewRequest } from '@/features/customer/actions'
import { CopyButton } from '@/components/app/copy-button'
import { LiveMap, type MapPoint } from '@/features/map/live-map'
import { PriceSummary, StatusBadge, StatusSteps, Timeline } from '@/features/requests/components'
import { requireRole } from '@/lib/auth/session'
import { formatKm, formatMoney, formatPhone } from '@/lib/format'
import { AppError, rpc } from '@/lib/rpc'
import type { PaymentInfo, ServiceRequest } from '@/lib/types'

export const metadata: Metadata = { title: 'Pedido' }

const headline: Record<ServiceRequest['status'], string> = {
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
  const live = !['completed', 'cancelled'].includes(request.status)
  const proposed = request.extras.filter((extra) => extra.status === 'proposed')
  const canCancel = ['searching', 'accepted', 'en_route'].includes(request.status)
  const mustPay = request.status === 'completed' && request.payment_status === 'pending'
  const payment = mustPay ? await rpc<PaymentInfo>('payment_info') : null
  const points: MapPoint[] = []
  if (live && request.lat !== null && request.lng !== null) {
    points.push({ lat: request.lat, lng: request.lng, label: 'Seu carro', kind: 'car' })
    if (request.provider?.lat != null && request.provider.lng != null && request.status !== 'in_progress') {
      points.push({ lat: request.provider.lat, lng: request.provider.lng, label: 'Prestador', kind: 'provider' })
    }
  }

  return (
    <>
      {/* Também enquanto o pagamento aguarda confirmação: a tela muda quando a HUB confere o Pix. */}
      {live || mustPay ? <AutoRefresh seconds={6} /> : null}
      <div className="flex items-center justify-between gap-3">
        <p className="text-sm text-muted-foreground">Pedido nº {request.number}</p>
        <StatusBadge status={request.status} />
      </div>
      <h1 className="mt-1 text-2xl font-semibold text-balance">{headline[request.status]}</h1>
      <p className="mt-1 text-muted-foreground">
        {request.service.name} · {request.vehicle.brand} {request.vehicle.model} ({request.vehicle.plate})
      </p>

      {request.status !== 'cancelled' ? <div className="mt-6"><StatusSteps status={request.status} /></div> : null}

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

      {mustPay && payment?.mode === 'demo' ? (
        <Panel className="mt-5 px-4 py-4">
          <p className="text-lg font-semibold">Pagamento</p>
          <p className="mt-1 text-sm text-muted-foreground">Confira o resumo abaixo e confirme o pagamento.</p>
          <ActionForm action={payRequest} successMessage="Pagamento confirmado." className="mt-3">
            <input type="hidden" name="id" value={request.id} />
            <SubmitButton size="lg" className="w-full">Pagar {formatMoney(request.total)}</SubmitButton>
          </ActionForm>
          <p className="mt-2 text-xs text-muted-foreground">Modo demonstração: o pagamento é simulado, nenhuma cobrança é feita.</p>
        </Panel>
      ) : null}

      {mustPay && payment?.mode === 'pix' ? (
        <Panel className="mt-5 px-4 py-4">
          <p className="text-lg font-semibold">Pague {formatMoney(request.total)} por Pix</p>
          {request.payment_claimed_at ? (
            <Notice tone="info" title="Aguardando a confirmação da HUB" className="mt-3">
              Você informou o pagamento. Assim que o Pix for conferido, o pedido é encerrado e você pode avaliar o atendimento.
            </Notice>
          ) : (
            <>
              <p className="mt-1 text-sm text-muted-foreground">Use a chave abaixo no aplicativo do seu banco e depois toque em “Já paguei”.</p>
              <dl className="mt-3 space-y-2 rounded-(--radius-control) bg-surface-2 px-3 py-3 text-sm">
                <div>
                  <dt className="text-muted-foreground">Chave Pix</dt>
                  <dd className="flex items-center justify-between gap-2 font-semibold break-all">
                    {payment.pix_key}
                    <CopyButton text={payment.pix_key ?? ''} />
                  </dd>
                </div>
                <div>
                  <dt className="text-muted-foreground">Favorecido</dt>
                  <dd className="font-semibold">{payment.pix_holder}</dd>
                </div>
                <div>
                  <dt className="text-muted-foreground">Valor · identificação</dt>
                  <dd className="font-semibold tabular-nums">{formatMoney(request.total)} · pedido nº {request.number}</dd>
                </div>
              </dl>
              <ActionForm action={claimPayment} successMessage="Pagamento informado." className="mt-3">
                <input type="hidden" name="id" value={request.id} />
                <SubmitButton size="lg" className="w-full">Já paguei</SubmitButton>
              </ActionForm>
            </>
          )}
        </Panel>
      ) : null}

      {request.status === 'completed' && request.payment_status === 'paid' && !request.review ? (
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
