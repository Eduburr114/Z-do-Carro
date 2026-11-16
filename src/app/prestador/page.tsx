import type { Metadata } from 'next'
import Link from 'next/link'
import { MapPin } from 'lucide-react'
import { AutoRefresh } from '@/components/app/auto-refresh'
import { RatingBadge, SectionTitle } from '@/components/app/bits'
import { buttonVariants } from '@/components/ui/button'
import { ActionForm, SubmitButton, TextareaField } from '@/components/ui/form'
import { Badge, Empty, Notice, Panel } from '@/components/ui/primitives'
import { acceptRequest, contestSuspension, declineRequest } from '@/features/provider/actions'
import { OnlineToggle, PositionBeacon } from '@/features/provider/online-toggle'
import { requireRole } from '@/lib/auth/session'
import { formatDateTime, formatKm, formatMoney, formatPercent, providerStatus } from '@/lib/format'
import { rpc } from '@/lib/rpc'
import type { ProviderHome, ServiceRequest } from '@/lib/types'

export const metadata: Metadata = { title: 'Início' }

const qualification = { requested: { label: 'Em análise', tone: 'warning' }, approved: { label: 'Habilitado', tone: 'success' }, rejected: { label: 'Não habilitado', tone: 'neutral' } } as const

export default async function ProviderHomePage() {
  const session = await requireRole('provider')
  const home = await rpc<ProviderHome>('provider_home')
  const ready = home.status === 'approved' && home.contract_ok
  const offers = ready && home.online && !home.active_request ? await rpc<ServiceRequest[]>('open_requests') : []
  const status = providerStatus[home.status]

  return (
    <>
      {ready && home.online ? <><AutoRefresh seconds={8} /><PositionBeacon /></> : null}
      <div className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold">Olá, {session.profile.full_name.split(' ')[0]}</h1>
          <div className="mt-1"><RatingBadge rating={home.rating} /></div>
        </div>
        <Badge tone={status.tone}>{status.label}</Badge>
      </div>

      <div className="mt-5 space-y-4">
        {['draft', 'rejected', 'closed'].includes(home.status) ? (
          <Panel className="px-4 py-5">
            <p className="text-lg font-semibold">
              {home.status === 'draft' ? 'Faça o seu credenciamento' : home.status === 'rejected' ? 'Credenciamento não aprovado' : 'Credenciamento encerrado'}
            </p>
            {home.status === 'rejected' && home.review_note ? (
              <Notice tone="danger" title="Motivo informado pela HUB" className="mt-3">{home.review_note}</Notice>
            ) : null}
            <p className="mt-2 text-sm text-muted-foreground">
              Informe seus dados e os serviços que você executa. A HUB analisa a documentação e a qualificação técnica antes de liberar os pedidos.
            </p>
            <Link href="/prestador/credenciamento" className={buttonVariants({ size: 'lg', className: 'mt-4 w-full' })}>
              {home.status === 'draft' ? 'Começar credenciamento' : 'Enviar novo credenciamento'}
            </Link>
          </Panel>
        ) : null}

        {home.status === 'pending' ? (
          <Notice tone="warning" title="Credenciamento em análise">
            Recebemos seus dados. Você será liberado para atender assim que a HUB concluir a análise técnica e documental.
          </Notice>
        ) : null}

        {home.status === 'suspended' && home.suspension ? (
          <Panel className="px-4 py-5">
            <p className="text-lg font-semibold">Credenciamento suspenso</p>
            <p className="mt-1 text-sm text-muted-foreground">
              Desde {formatDateTime(home.suspension.created_at)}{home.suspension.precautionary ? ' · medida cautelar' : ''}
            </p>
            <Notice tone="danger" title="Motivo" className="mt-3">{home.suspension.reason}</Notice>
            {home.suspension.contested_at ? (
              <Notice tone="info" title="Contestação enviada" className="mt-3">
                {home.suspension.contest_text}
                <span className="mt-1 block text-muted-foreground">A HUB vai rever a medida e registrar a decisão aqui.</span>
              </Notice>
            ) : (
              <ActionForm action={contestSuspension} successMessage="Contestação enviada." className="mt-4">
                <input type="hidden" name="id" value={home.suspension.id} />
                <TextareaField label="Contestar a suspensão" name="text" rows={4} hint="Explique os fatos e indique os documentos que comprovam." />
                <SubmitButton className="w-full">Enviar contestação</SubmitButton>
              </ActionForm>
            )}
          </Panel>
        ) : null}

        {['pending', 'approved'].includes(home.status) && !home.contract_ok ? (
          <Panel className="border-2 border-brand px-4 py-5">
            <p className="text-lg font-semibold">Aceite o contrato de credenciamento</p>
            <p className="mt-1 text-sm text-muted-foreground">Você só recebe pedidos depois de ler e aceitar a versão vigente.</p>
            <Link href="/prestador/contrato" className={buttonVariants({ className: 'mt-3 w-full' })}>Ler e aceitar o contrato</Link>
          </Panel>
        ) : null}

        {ready ? <OnlineToggle online={home.online} /> : null}

        {home.active_request ? (
          <Link href={`/prestador/pedidos/${home.active_request}`} className="block rounded-(--radius-panel) bg-brand px-4 py-4 text-brand-foreground">
            <p className="text-lg font-semibold">Você tem um atendimento em andamento</p>
            <p className="text-sm font-medium opacity-80">Toque para abrir</p>
          </Link>
        ) : null}
      </div>

      {ready && home.online && !home.active_request ? (
        <>
          <SectionTitle>Pedidos na sua região</SectionTitle>
          {offers.length === 0 ? (
            <Panel><Empty title="Nenhum pedido agora">Esta tela se atualiza sozinha. Recusar um pedido não afeta a sua nota.</Empty></Panel>
          ) : (
            <ul className="space-y-3">
              {offers.map((offer) => (
                <li key={offer.id}>
                  <Panel className="px-4 py-4">
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <p className="text-lg font-semibold">{offer.service.name}</p>
                        <p className="text-sm text-muted-foreground">
                          {offer.vehicle.brand} {offer.vehicle.model}{offer.vehicle.year ? ` ${offer.vehicle.year}` : ''} · cerca de {offer.service.est_minutes} min
                        </p>
                      </div>
                      <div className="text-right">
                        <p className="text-xs font-semibold text-muted-foreground">Você recebe</p>
                        <p className="font-display text-2xl font-semibold tabular-nums">{formatMoney(offer.provider_net)}</p>
                      </div>
                    </div>
                    <p className="mt-2 flex items-start gap-1.5 text-sm">
                      <MapPin className="mt-0.5 size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
                      <span>{offer.address}{offer.distance_km !== null ? ` · ${formatKm(offer.distance_km)}` : ''}</span>
                    </p>
                    <p className="mt-1 text-sm text-muted-foreground">
                      Preço ao cliente {formatMoney(offer.price)} · comissão da HUB {formatPercent(offer.commission_percent)} ({formatMoney(offer.commission_amount)})
                    </p>
                    <div className="mt-3 grid grid-cols-2 gap-2">
                      <ActionForm action={declineRequest}>
                        <input type="hidden" name="id" value={offer.id} />
                        <SubmitButton variant="outline" className="w-full">Recusar</SubmitButton>
                      </ActionForm>
                      <ActionForm action={acceptRequest}>
                        <input type="hidden" name="id" value={offer.id} />
                        <SubmitButton className="w-full">Aceitar</SubmitButton>
                      </ActionForm>
                    </div>
                  </Panel>
                </li>
              ))}
            </ul>
          )}
        </>
      ) : null}

      {home.services.length > 0 ? (
        <>
          <SectionTitle>Seus serviços</SectionTitle>
          <Panel>
            <ul className="divide-y divide-border">
              {home.services.map((service) => (
                <li key={service.id} className="flex items-center justify-between gap-3 px-4 py-3">
                  <span className="font-medium">{service.name}</span>
                  <Badge tone={qualification[service.status].tone}>{qualification[service.status].label}</Badge>
                </li>
              ))}
            </ul>
          </Panel>
        </>
      ) : null}
    </>
  )
}
