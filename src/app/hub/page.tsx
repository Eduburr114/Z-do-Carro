import type { Metadata } from 'next'
import Link from 'next/link'
import { SectionTitle } from '@/components/app/bits'
import { Notice, Stat } from '@/components/ui/primitives'
import { requireRole } from '@/lib/auth/session'
import { formatMoney, formatPercent } from '@/lib/format'
import { rpc } from '@/lib/rpc'
import type { Rating } from '@/lib/types'

export const metadata: Metadata = { title: 'Visão geral' }

type Overview = {
  providers: { pending: number; approved: number; online: number; suspended: number }
  contests: number
  payments_to_confirm: number
  customers: number
  requests: { searching: number; active: number; completed: number; cancelled: number; gross: number; commission: number; payouts_pending: number; awaiting_payment: number }
  rating: Rating
  settings: { commission_percent: number; payout_days: number; search_radius_km: number; pix_key: string | null }
  contract: { version: string; title: string } | null
}

export default async function HubOverview() {
  await requireRole('hub_admin')
  const o = await rpc<Overview>('admin_overview')
  return (
    <>
      <h1 className="mb-4 text-2xl font-semibold">Visão geral</h1>

      <div className="space-y-3">
        {o.providers.pending > 0 ? (
          <Notice tone="warning" title={`${o.providers.pending} credenciamento(s) aguardando análise`}>
            <Link href="/hub/prestadores" className="font-semibold underline">Analisar agora</Link>
          </Notice>
        ) : null}
        {o.contests > 0 ? (
          <Notice tone="warning" title={`${o.contests} contestação(ões) de suspensão para rever`}>
            <Link href="/hub/prestadores" className="font-semibold underline">Abrir prestadores</Link>
          </Notice>
        ) : null}
        {o.payments_to_confirm > 0 ? (
          <Notice tone="warning" title={`${o.payments_to_confirm} pagamento(s) por Pix para conferir`}>
            <Link href="/hub/pedidos" className="font-semibold underline">Confirmar recebimentos</Link>
          </Notice>
        ) : null}
        {o.requests.searching > 0 ? (
          <Notice tone="info" title={`${o.requests.searching} pedido(s) procurando prestador`}>
            <Link href="/hub/pedidos" className="font-semibold underline">Ver pedidos</Link>
          </Notice>
        ) : null}
      </div>

      <SectionTitle>Operação</SectionTitle>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="Em atendimento" value={o.requests.active} />
        <Stat label="Concluídos" value={o.requests.completed} />
        <Stat label="Cancelados" value={o.requests.cancelled} />
        <Stat label="Nota média" value={o.rating.average !== null ? `${o.rating.average.toLocaleString('pt-BR', { minimumFractionDigits: 1 })} ★` : '—'} hint={`${o.rating.count} avaliação(ões)`} />
      </div>

      <SectionTitle>Rede</SectionTitle>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="Prestadores credenciados" value={o.providers.approved} />
        <Stat label="Disponíveis agora" value={o.providers.online} tone="success" />
        <Stat label="Suspensos" value={o.providers.suspended} />
        <Stat label="Clientes" value={o.customers} />
      </div>

      <SectionTitle>Financeiro</SectionTitle>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="Pago pelos clientes" value={formatMoney(o.requests.gross)} />
        <Stat label="Comissão da HUB" value={formatMoney(o.requests.commission)} tone="success" hint={`Atual: ${formatPercent(o.settings.commission_percent)}`} />
        <Stat label="Repasses pendentes" value={formatMoney(o.requests.payouts_pending)} tone={o.requests.payouts_pending > 0 ? 'warning' : undefined} />
        <Stat label="Aguardando cliente pagar" value={formatMoney(o.requests.awaiting_payment)} />
      </div>

      <Notice tone="warning" title="Antes de operar com clientes reais" className="mt-7">
        <ul className="mt-1 list-disc space-y-1 pl-5">
          <li>O contrato publicado é a versão {o.contract?.version ?? '—'}, uma minuta com campos a preencher ([CNPJ], [PERCENTUAL], [PRAZO]) e pendente de revisão jurídica.</li>
          <li>
            {o.settings.pix_key
              ? 'Pagamento por Pix com confirmação manual da HUB. Para volume maior, integre um provedor de pagamentos com divisão automática.'
              : 'O pagamento está em modo demonstração (simulado). Cadastre a chave Pix da HUB em Ajustes para receber de verdade.'}
          </li>
          <li>Os Termos de Uso e a Política de Privacidade publicados também são minutas.</li>
          <li>Preços, comissão e prazo de repasse são valores de partida, ajustáveis em Ajustes.</li>
        </ul>
      </Notice>
    </>
  )
}
