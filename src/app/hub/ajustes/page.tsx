import type { Metadata } from 'next'
import Link from 'next/link'
import { ActionForm, Field, MoneyField, SelectField, SubmitButton } from '@/components/ui/form'
import { Notice, PageHeader, Panel } from '@/components/ui/primitives'
import { saveFinanceSettings, savePix, saveSearchRadius } from '@/features/hub/actions'
import { SettingsTabs } from '@/features/hub/tabs'
import { requireStaff } from '@/lib/auth/session'
import { paymentsReady } from '@/lib/finance/status'
import { rpc } from '@/lib/rpc'

export const metadata: Metadata = { title: 'Ajustes' }

type Settings = {
  commission_percent: number; payout_days: number; search_radius_km: number; pix_key: string | null; pix_holder: string | null
  payment_provider: 'asaas' | 'manual'; payout_mode: 'asaas' | 'manual'; payment_window_minutes: number; confirm_hours: number
  platform_fee: number; min_charge_amount: number; account_cooldown_hours: number
}
const brl = (value: number) => Number(value).toFixed(2).replace('.', ',')

export default async function SettingsPage() {
  await requireStaff('admin')
  const { settings: s } = await rpc<{ settings: Settings }>('admin_overview')
  const ready = paymentsReady()
  return (
    <>
      <PageHeader title="Ajustes">
        <Link href="/conta" className="text-sm font-semibold underline">Minha conta</Link>
      </PageHeader>
      <SettingsTabs current="/hub/ajustes" />

      <Panel className="px-4 py-4 sm:px-5">
        <h2 className="text-base font-semibold">Regras financeiras</h2>
        <p className="mt-0.5 mb-4 text-sm text-muted-foreground">
          Valem para pedidos novos: cada pedido guarda o preço, a comissão e o prazo vigentes na contratação. Mudança relevante pede nova versão do contrato e novo aceite (cláusula 15.2). Comissões por categoria, prestador ou campanha ficam em “Comissões e promoções”.
        </p>
        <ActionForm action={saveFinanceSettings} successMessage="Regras salvas." resetOnSuccess={false}>
          <div className="grid gap-3 sm:grid-cols-3">
            <Field label="Comissão padrão da HUB (%)" name="commission_percent" inputMode="decimal" defaultValue={String(s.commission_percent).replace('.', ',')} />
            <Field label="Repasse após a confirmação (dias)" name="payout_days" inputMode="numeric" defaultValue={s.payout_days} />
            <Field label="Prazo para o cliente confirmar (horas)" name="confirm_hours" inputMode="numeric" defaultValue={s.confirm_hours} />
            <Field label="Prazo para pagar o pedido (minutos)" name="payment_window_minutes" inputMode="numeric" defaultValue={s.payment_window_minutes} />
            <MoneyField label="Taxa da plataforma ao cliente (R$)" name="platform_fee" defaultValue={brl(s.platform_fee)} hint="Mostrada ao cliente antes de pagar. 0 = sem taxa." />
            <MoneyField label="Cobrança mínima (R$)" name="min_charge_amount" defaultValue={brl(s.min_charge_amount)} hint="Confira o mínimo do provedor." />
            <SelectField label="Recebimento dos clientes" name="payment_provider" defaultValue={s.payment_provider}>
              <option value="asaas">Pix automático (Asaas)</option>
              <option value="manual">Pix manual (conferência da equipe)</option>
            </SelectField>
            <SelectField label="Repasse aos prestadores" name="payout_mode" defaultValue={s.payout_mode}>
              <option value="asaas">Transferência Pix automática (Asaas)</option>
              <option value="manual">Manual (equipe registra o comprovante)</option>
            </SelectField>
            <Field label="Carência de conta Pix nova (horas)" name="account_cooldown_hours" inputMode="numeric" defaultValue={s.account_cooldown_hours} />
          </div>
          <SubmitButton>Salvar regras financeiras</SubmitButton>
        </ActionForm>
      </Panel>

      <Panel className="mt-3 px-4 py-4 sm:px-5">
        <h2 className="text-base font-semibold">Integrações no servidor</h2>
        <p className="mt-0.5 mb-3 text-sm text-muted-foreground">As chaves ficam só nas variáveis de ambiente da hospedagem; nunca aqui nem no navegador.</p>
        <ul className="space-y-1 text-sm">
          <li>{ready.asaas ? '✓' : '✗'} Asaas {ready.asaas ? `(${ready.asaasEnv === 'production' ? 'produção' : 'sandbox'})` : '— defina ASAAS_API_KEY'}</li>
          <li>{ready.webhook ? '✓' : '✗'} Webhook do Asaas {ready.webhook ? '' : '— defina ASAAS_WEBHOOK_TOKEN'}</li>
          <li>{ready.transferValidation ? '✓' : '—'} Validação de saque {ready.transferValidation ? '' : '(recomendada) — ASAAS_TRANSFER_VALIDATION_TOKEN'}</li>
          <li>{ready.cron ? '✓' : '✗'} Rotina financeira {ready.cron ? '' : '— defina CRON_SECRET e o agendador'}</li>
          <li>{ready.email ? '✓' : '✗'} E-mails (Resend) {ready.email ? '' : '— defina RESEND_API_KEY e EMAIL_FROM'}</li>
        </ul>
        {s.payment_provider === 'asaas' && !ready.asaas ? (
          <Notice tone="danger" className="mt-3">O recebimento está em “Pix automático”, mas o Asaas não está configurado: os clientes não conseguem pagar.</Notice>
        ) : null}
      </Panel>

      <Panel className="mt-3 px-4 py-4 sm:px-5">
        <h2 className="text-base font-semibold">Chave Pix da HUB (modo manual)</h2>
        <p className="mt-0.5 mb-4 text-sm text-muted-foreground">
          Usada só no recebimento manual: o cliente paga para esta chave e a equipe financeira confirma com o identificador da transação.
        </p>
        <ActionForm action={savePix} successMessage="Chave salva." resetOnSuccess={false}>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="Chave Pix da HUB" name="pix_key" defaultValue={s.pix_key ?? ''} autoComplete="off" />
            <Field label="Favorecido (como aparece no banco)" name="pix_holder" defaultValue={s.pix_holder ?? ''} autoComplete="off" />
          </div>
          <SubmitButton variant="secondary">Salvar chave</SubmitButton>
        </ActionForm>
      </Panel>

      <Panel className="mt-3 px-4 py-4 sm:px-5">
        <h2 className="text-base font-semibold">Busca de prestadores</h2>
        <ActionForm action={saveSearchRadius} successMessage="Raio salvo." resetOnSuccess={false} className="mt-3">
          <Field label="Raio máximo de busca (km)" name="search_radius_km" inputMode="numeric" defaultValue={s.search_radius_km} className="max-w-xs" />
          <SubmitButton variant="secondary">Salvar raio</SubmitButton>
        </ActionForm>
      </Panel>
    </>
  )
}
