import type { Metadata } from 'next'
import Link from 'next/link'
import { SectionTitle } from '@/components/app/bits'
import { Notice, Stat } from '@/components/ui/primitives'
import { requireStaff } from '@/lib/auth/session'
import { paymentsReady } from '@/lib/finance/status'
import { formatPercent } from '@/lib/format'
import { rpc } from '@/lib/rpc'
import type { Rating } from '@/lib/types'

export const metadata: Metadata = { title: 'Visão geral' }

type Overview = {
  providers: { pending: number; approved: number; online: number; suspended: number }
  contests: number
  payments_to_confirm: number
  customers: number
  requests: { awaiting_payment: number; searching: number; active: number; completed: number; cancelled: number }
  rating: Rating
  settings: { commission_percent: number; payout_days: number; search_radius_km: number; pix_key: string | null; payment_provider: 'asaas' | 'manual'; payout_mode: 'asaas' | 'manual' }
  contract: { version: string; title: string } | null
}

export default async function HubOverview() {
  const session = await requireStaff('admin')
  const o = await rpc<Overview>('admin_overview')
  const ready = paymentsReady()
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
            <Link href="/hub/financeiro/pagamentos?status=claimed" className="font-semibold underline">Confirmar recebimentos</Link>
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
        <Stat label="Aguardando pagamento" value={o.requests.awaiting_payment} />
        <Stat label="Comissão padrão" value={formatPercent(o.settings.commission_percent)} hint={`Repasse em ${o.settings.payout_days} dias`} />
      </div>
      {session.staff.includes('finance') ? (
        <p className="mt-2 text-sm"><Link href="/hub/financeiro" className="font-semibold underline">Abrir o painel financeiro</Link></p>
      ) : null}

      <Notice tone="warning" title="Antes de operar com clientes reais" className="mt-7">
        <ul className="mt-1 list-disc space-y-1 pl-5">
          <li>O contrato publicado é a versão {o.contract?.version ?? '—'}, uma minuta com campos a preencher ([CNPJ], [PERCENTUAL], [PRAZO]) e pendente de revisão jurídica.</li>
          <li>
            {o.settings.payment_provider === 'manual'
              ? 'Pagamento por Pix manual: a equipe financeira confere cada recebimento. Para volume maior, use a cobrança automática (Asaas).'
              : ready.asaas
                ? `Cobrança Pix automática pelo Asaas (${ready.asaasEnv === 'production' ? 'produção' : 'sandbox: nenhum dinheiro real'}).`
                : 'Cobrança automática selecionada, mas o Asaas ainda não foi configurado no servidor (ASAAS_API_KEY). Os clientes não conseguem pagar.'}
          </li>
          {!ready.webhook ? <li>Webhook do Asaas sem token (ASAAS_WEBHOOK_TOKEN): as confirmações automáticas não chegam.</li> : null}
          {!ready.cron ? <li>Rotina financeira sem segredo (CRON_SECRET): prazos, repasses e estornos não rodam sozinhos.</li> : null}
          {!ready.email ? <li>E-mails transacionais desligados (RESEND_API_KEY e EMAIL_FROM): os avisos por e-mail ficam só registrados.</li> : null}
          <li>Os Termos de Uso e a Política de Privacidade publicados também são minutas.</li>
          <li>Preços, comissão e prazo de repasse são valores de partida, ajustáveis em Ajustes.</li>
        </ul>
      </Notice>
    </>
  )
}
