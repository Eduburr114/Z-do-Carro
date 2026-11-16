import type { Metadata } from 'next'
import Link from 'next/link'
import { SectionTitle } from '@/components/app/bits'
import { ActionForm, Field, SelectField, SubmitButton } from '@/components/ui/form'
import { Badge, Empty, Notice, Panel, Stat } from '@/components/ui/primitives'
import { savePaymentAccount } from '@/features/provider/actions'
import { requireRole } from '@/lib/auth/session'
import { formatDate, formatDateTime, formatMoney, holdReason, payoutStatus } from '@/lib/format'
import { requestTime } from '@/lib/clock'
import { rpc } from '@/lib/rpc'
import type { PayoutStatus } from '@/lib/types'

export const metadata: Metadata = { title: 'Ganhos' }

type Finance = {
  summary: { scheduled: number; on_hold: number; processing: number; received: number }
  awaiting_confirmation: number
  account: { pix_key_type: string; pix_key_masked: string; holder_name: string; usable_from: string } | null
  pending_account: { pix_key_type: string; created_at: string } | null
  rejected_account: { review_note: string; reviewed_at: string } | null
  payouts: { id: string; request_id: string; number: number; service: string; amount: number; status: PayoutStatus; scheduled_for: string; completed_at: string | null; hold_reason: string | null; final_failure: boolean }[]
}

const keyTypes = [
  ['CPF', 'CPF'], ['CNPJ', 'CNPJ'], ['EMAIL', 'E-mail'], ['PHONE', 'Celular'], ['EVP', 'Chave aleatória'],
] as const

export default async function EarningsPage() {
  await requireRole('provider')
  const f = await rpc<Finance>('provider_finance')
  const coolingDown = f.account && new Date(f.account.usable_from).getTime() > requestTime()
  return (
    <>
      <h1 className="mb-4 text-2xl font-semibold">Ganhos</h1>
      <div className="grid grid-cols-2 gap-3">
        <Stat label="Repasses agendados" value={formatMoney(f.summary.scheduled)} hint="Saem na data prevista" />
        <Stat label="Recebido" value={formatMoney(f.summary.received)} tone="success" />
        <Stat label="Aguardando o cliente confirmar" value={formatMoney(f.awaiting_confirmation)} />
        <Stat label="Retido ou em processamento" value={formatMoney(f.summary.on_hold + f.summary.processing)} tone={f.summary.on_hold > 0 ? 'warning' : undefined} />
      </div>
      <p className="mt-3 text-sm text-muted-foreground">
        Valores líquidos, já sem a comissão da HUB. O repasse é agendado quando o cliente confirma o serviço e sai por Pix no prazo do contrato.
      </p>

      <SectionTitle>Conta para receber</SectionTitle>
      {!f.account && !f.pending_account ? (
        <Notice tone="warning" title="Cadastre a sua chave Pix" className="mb-3">Sem uma chave conferida pela HUB, os repasses ficam esperando.</Notice>
      ) : null}
      {f.rejected_account && !f.pending_account ? (
        <Notice tone="danger" title="A última chave cadastrada foi recusada" className="mb-3">{f.rejected_account.review_note}</Notice>
      ) : null}
      <Panel className="px-4 py-4">
        {f.account ? (
          <div className="mb-4">
            <p className="text-sm text-muted-foreground">Chave ativa</p>
            <p className="font-semibold">{f.account.pix_key_type} · {f.account.pix_key_masked}</p>
            <p className="text-sm text-muted-foreground">{f.account.holder_name}</p>
            {coolingDown ? <p className="mt-1 text-sm text-warning">Período de segurança até {formatDateTime(f.account.usable_from)}.</p> : null}
          </div>
        ) : null}
        {f.pending_account ? (
          <Notice tone="info" className="mb-4">
            Nova chave ({f.pending_account.pix_key_type}) enviada em {formatDateTime(f.pending_account.created_at)}, aguardando conferência da HUB.
          </Notice>
        ) : null}
        <details open={!f.account && !f.pending_account}>
          <summary className="cursor-pointer font-semibold">{f.account ? 'Trocar a chave Pix' : 'Cadastrar chave Pix'}</summary>
          <ActionForm action={savePaymentAccount} successMessage="Chave enviada para conferência." className="mt-3">
            <SelectField label="Tipo da chave" name="pix_key_type" defaultValue="CPF">
              {keyTypes.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
            </SelectField>
            <Field label="Chave Pix" name="pix_key" autoComplete="off" required />
            <Field label="Nome do titular da conta" name="holder_name" autoComplete="name" required />
            <p className="text-sm text-muted-foreground">
              A conta precisa estar no CPF/CNPJ do seu credenciamento. Por segurança, toda troca passa por conferência e por um período de espera antes do primeiro repasse, e você recebe um aviso por e-mail.
            </p>
            <SubmitButton className="w-full">Enviar para conferência</SubmitButton>
          </ActionForm>
        </details>
      </Panel>

      <SectionTitle>Repasses</SectionTitle>
      {f.payouts.length === 0 ? (
        <Panel><Empty title="Nenhum repasse ainda">O repasse aparece aqui depois que o cliente confirma o serviço.</Empty></Panel>
      ) : (
        <Panel>
          <ul className="divide-y divide-border">
            {f.payouts.map((p) => (
              <li key={p.id}>
                <Link href={`/prestador/pedidos/${p.request_id}`} className="flex items-center justify-between gap-3 px-4 py-3 hover:bg-surface-2">
                  <div className="min-w-0">
                    <p className="font-semibold">nº {p.number} · {p.service}</p>
                    <p className="text-sm text-muted-foreground">
                      {p.status === 'completed' ? `Transferido em ${formatDate(p.completed_at)}` : p.status === 'on_hold' ? holdReason(p.hold_reason) : `Previsto para ${formatDate(p.scheduled_for)}`}
                    </p>
                  </div>
                  <div className="text-right">
                    <p className="font-semibold tabular-nums">{formatMoney(p.amount)}</p>
                    <Badge tone={payoutStatus[p.status].tone}>{p.final_failure ? 'Falhou' : payoutStatus[p.status].label}</Badge>
                  </div>
                </Link>
              </li>
            ))}
          </ul>
        </Panel>
      )}
    </>
  )
}
