import type { Metadata } from 'next'
import { SectionTitle } from '@/components/app/bits'
import { ActionForm, CheckboxField, Field, MoneyField, SubmitButton } from '@/components/ui/form'
import { Panel } from '@/components/ui/primitives'
import { savePix, saveService, saveSettings } from '@/features/hub/actions'
import { SetupCode } from '@/features/hub/setup-code'
import { requireRole } from '@/lib/auth/session'
import { rpc } from '@/lib/rpc'
import type { Service } from '@/lib/types'

export const metadata: Metadata = { title: 'Ajustes' }

type Overview = {
  settings: { commission_percent: number; payout_days: number; search_radius_km: number; pix_key: string | null; pix_holder: string | null; setup_code_pending: boolean }
}
const brl = (value: number) => Number(value).toFixed(2).replace('.', ',')

function ServiceForm({ service }: { service?: Service }) {
  return (
    <ActionForm action={saveService} successMessage="Serviço salvo." resetOnSuccess={!service}>
      <input type="hidden" name="id" value={service?.id ?? ''} />
      <Field label="Nome" name="name" defaultValue={service?.name} required />
      <Field label="Descrição para o cliente" name="description" defaultValue={service?.description} />
      <div className="grid grid-cols-2 gap-3">
        <MoneyField label="Preço ao cliente (R$)" name="base_price" defaultValue={service ? brl(service.base_price) : ''} />
        <Field label="Duração (min)" name="est_minutes" inputMode="numeric" defaultValue={service?.est_minutes} />
      </div>
      <CheckboxField name="active" label="Disponível para pedidos" defaultChecked={service?.active ?? true} />
      <SubmitButton variant={service ? 'secondary' : 'primary'}>{service ? 'Salvar' : 'Adicionar serviço'}</SubmitButton>
    </ActionForm>
  )
}

export default async function SettingsPage() {
  await requireRole('hub_admin')
  const [{ settings }, services] = await Promise.all([rpc<Overview>('admin_overview'), rpc<Service[]>('admin_services')])
  return (
    <>
      <h1 className="mb-4 text-2xl font-semibold">Ajustes</h1>

      <Panel className="px-4 py-4 sm:px-5">
        <h2 className="text-base font-semibold">Regras financeiras</h2>
        <p className="mt-0.5 mb-4 text-sm text-muted-foreground">
          Valem para pedidos novos. Pedidos já criados mantêm a comissão que o prestador viu ao aceitar. Mudança relevante pede nova versão do contrato e novo aceite (cláusula 15.2).
        </p>
        <ActionForm action={saveSettings} successMessage="Regras salvas." resetOnSuccess={false}>
          <div className="grid gap-3 sm:grid-cols-3">
            <Field label="Comissão da HUB (%)" name="commission_percent" inputMode="decimal" defaultValue={String(settings.commission_percent).replace('.', ',')} />
            <Field label="Repasse em até (dias)" name="payout_days" inputMode="numeric" defaultValue={settings.payout_days} />
            <Field label="Raio máximo de busca (km)" name="search_radius_km" inputMode="numeric" defaultValue={settings.search_radius_km} />
          </div>
          <SubmitButton>Salvar regras</SubmitButton>
        </ActionForm>
      </Panel>

      <Panel className="mt-3 px-4 py-4 sm:px-5">
        <h2 className="text-base font-semibold">Recebimento por Pix</h2>
        <p className="mt-0.5 mb-4 text-sm text-muted-foreground">
          {settings.pix_key
            ? 'Os clientes pagam por Pix para esta chave e a HUB confirma cada recebimento em Pedidos. Deixe a chave em branco para voltar ao modo demonstração.'
            : 'Sem chave cadastrada, o aplicativo fica em modo demonstração: o pagamento é simulado e nada é cobrado. Cadastre a chave para receber de verdade.'}
        </p>
        <ActionForm action={savePix} successMessage="Recebimento salvo." resetOnSuccess={false}>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="Chave Pix da HUB" name="pix_key" defaultValue={settings.pix_key ?? ''} autoComplete="off" />
            <Field label="Favorecido (como aparece no banco)" name="pix_holder" defaultValue={settings.pix_holder ?? ''} autoComplete="off" />
          </div>
          <SubmitButton>Salvar recebimento</SubmitButton>
        </ActionForm>
      </Panel>

      <Panel className="mt-3 px-4 py-4 sm:px-5">
        <h2 className="text-base font-semibold">Equipe da HUB</h2>
        <p className="mt-0.5 mb-4 text-sm text-muted-foreground">Para dar acesso ao painel a outra pessoa da equipe, gere um código de ativação e entregue a ela.</p>
        <SetupCode pending={settings.setup_code_pending} />
      </Panel>

      <SectionTitle>Catálogo de serviços</SectionTitle>
      <div className="grid gap-3 sm:grid-cols-2">
        {services.map((service) => (
          <Panel key={service.id} className="px-4 py-4"><ServiceForm service={service} /></Panel>
        ))}
        <Panel className="px-4 py-4">
          <h3 className="mb-3 font-semibold">Novo serviço</h3>
          <ServiceForm />
        </Panel>
      </div>
    </>
  )
}
