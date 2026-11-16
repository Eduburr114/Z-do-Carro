import type { Metadata } from 'next'
import { SectionTitle } from '@/components/app/bits'
import { ActionForm, CheckboxField, Field, MoneyField, SelectField, SubmitButton } from '@/components/ui/form'
import { Panel, PageHeader, Table } from '@/components/ui/primitives'
import { saveCategory, saveRegion, saveService, setRegionPrice } from '@/features/hub/actions'
import { SettingsTabs } from '@/features/hub/tabs'
import { requireStaff } from '@/lib/auth/session'
import { formatDateTime } from '@/lib/format'
import { rpc } from '@/lib/rpc'

export const metadata: Metadata = { title: 'Catálogo e preços' }

export type Catalog = {
  categories: { code: string; name: string; sort: number; active: boolean }[]
  regions: { id: string; code: string; name: string; uf: string; center_lat: number; center_lng: number; radius_km: number; active: boolean; is_default: boolean }[]
  services: { id: string; code: string; name: string; description: string; base_price: number; est_minutes: number; active: boolean; category_code: string; prices: { region_id: string; price: number; active: boolean }[] }[]
  promotions: { id: string; name: string; kind: 'percent' | 'fixed'; value: number; service_id: string | null; category_code: string | null; region_id: string | null; starts_at: string; ends_at: string; max_redemptions: number | null; redemptions: number; active: boolean; running: boolean }[]
  commission_rules: { id: string; name: string; scope: 'category' | 'provider' | 'campaign'; category_code: string | null; provider_id: string | null; provider_name: string | null; percent: number; starts_at: string | null; ends_at: string | null; active: boolean; running: boolean; created_at: string }[]
  providers: { id: string; name: string }[]
}
type History = { id: number; at: string; actor: string | null; action: string; entity: string; entity_id: string; before: Record<string, unknown> | null; after: Record<string, unknown> | null }

const brl = (value: number) => Number(value).toFixed(2).replace('.', ',')
const entityLabel: Record<string, string> = {
  services: 'Serviço', service_prices: 'Preço por região', promotions: 'Promoção', commission_rules: 'Regra de comissão',
  settings: 'Regras gerais', regions: 'Região', service_categories: 'Categoria',
}
/** Resumo legível do que mudou entre o antes e o depois. */
function changes(h: History): string {
  const keys = ['name', 'base_price', 'price', 'active', 'percent', 'value', 'commission_percent', 'payout_days', 'platform_fee', 'confirm_hours', 'payment_provider', 'payout_mode', 'ends_at']
  const parts = keys.filter((k) => h.after && k in h.after && JSON.stringify(h.before?.[k]) !== JSON.stringify(h.after[k]))
    .map((k) => `${k}: ${h.before?.[k] ?? '—'} → ${h.after?.[k]}`)
  return parts.join(' · ') || (h.action === 'delete' ? 'removido' : h.action === 'insert' ? 'criado' : 'alterado')
}

export default async function CatalogPage() {
  await requireStaff('admin')
  const [catalog, history] = await Promise.all([rpc<Catalog>('admin_catalog'), rpc<History[]>('admin_price_history', { p_limit: 40 })])
  return (
    <>
      <PageHeader title="Ajustes" />
      <SettingsTabs current="/hub/ajustes/catalogo" />
      <p className="mb-4 text-sm text-muted-foreground">
        Preços mudam na hora, sem publicar nova versão do aplicativo. Cada pedido guarda o preço aceito; mudanças valem só para pedidos novos e ficam no histórico.
      </p>

      <SectionTitle>Serviços</SectionTitle>
      <div className="grid gap-3 sm:grid-cols-2">
        {catalog.services.map((service) => (
          <Panel key={service.id} className="px-4 py-4">
            <ActionForm action={saveService} successMessage="Serviço salvo." resetOnSuccess={false}>
              <input type="hidden" name="id" value={service.id} />
              <Field label="Nome" name="name" defaultValue={service.name} required />
              <Field label="Descrição para o cliente" name="description" defaultValue={service.description} />
              <SelectField label="Categoria" name="category_code" defaultValue={service.category_code}>
                {catalog.categories.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}
              </SelectField>
              <div className="grid grid-cols-2 gap-3">
                <MoneyField label="Preço de tabela (R$)" name="base_price" defaultValue={brl(service.base_price)} />
                <Field label="Duração (min)" name="est_minutes" inputMode="numeric" defaultValue={service.est_minutes} />
              </div>
              <CheckboxField name="active" label="Disponível para pedidos" defaultChecked={service.active} />
              <SubmitButton variant="secondary">Salvar serviço</SubmitButton>
            </ActionForm>
            {catalog.regions.map((region) => {
              const price = service.prices.find((p) => p.region_id === region.id)
              return (
                <ActionForm key={region.id} action={setRegionPrice} successMessage="Preço da região salvo." resetOnSuccess={false} className="mt-3 border-t border-border pt-3">
                  <input type="hidden" name="service_id" value={service.id} />
                  <input type="hidden" name="region_id" value={region.id} />
                  <div className="flex items-end gap-2">
                    <MoneyField label={`Preço em ${region.name} (R$)`} name="price" defaultValue={price ? brl(price.price) : ''} hint="Em branco: preço de tabela." className="flex-1" />
                    <SubmitButton variant="outline" size="sm" className="mb-7">Salvar</SubmitButton>
                  </div>
                </ActionForm>
              )
            })}
          </Panel>
        ))}
        <Panel className="px-4 py-4">
          <h3 className="mb-3 font-semibold">Novo serviço</h3>
          <ActionForm action={saveService} successMessage="Serviço criado.">
            <input type="hidden" name="id" value="" />
            <Field label="Nome" name="name" required />
            <Field label="Descrição para o cliente" name="description" />
            <SelectField label="Categoria" name="category_code" defaultValue={catalog.categories[0]?.code}>
              {catalog.categories.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}
            </SelectField>
            <div className="grid grid-cols-2 gap-3">
              <MoneyField label="Preço de tabela (R$)" name="base_price" />
              <Field label="Duração (min)" name="est_minutes" inputMode="numeric" />
            </div>
            <CheckboxField name="active" label="Disponível para pedidos" defaultChecked />
            <SubmitButton>Adicionar serviço</SubmitButton>
          </ActionForm>
        </Panel>
      </div>

      <SectionTitle>Categorias</SectionTitle>
      <div className="grid gap-3 sm:grid-cols-2">
        {[...catalog.categories, { code: '', name: '', sort: 100, active: true }].map((c) => (
          <Panel key={c.code || 'nova'} className="px-4 py-4">
            <ActionForm action={saveCategory} successMessage="Categoria salva." resetOnSuccess={!c.code}>
              <div className="grid grid-cols-2 gap-3">
                <Field label="Código" name="code" defaultValue={c.code} readOnly={Boolean(c.code)} placeholder="ex.: eletrica" />
                <Field label="Ordem" name="sort" inputMode="numeric" defaultValue={c.sort} />
              </div>
              <Field label="Nome" name="name" defaultValue={c.name} placeholder={c.code ? undefined : 'Nova categoria'} />
              <CheckboxField name="active" label="Ativa" defaultChecked={c.active} />
              <SubmitButton variant={c.code ? 'secondary' : 'primary'}>{c.code ? 'Salvar' : 'Adicionar categoria'}</SubmitButton>
            </ActionForm>
          </Panel>
        ))}
      </div>

      <SectionTitle>Regiões de atendimento</SectionTitle>
      <div className="grid gap-3 sm:grid-cols-2">
        {[...catalog.regions, null].map((r) => (
          <Panel key={r?.id ?? 'nova'} className="px-4 py-4">
            <ActionForm action={saveRegion} successMessage="Região salva." resetOnSuccess={!r}>
              <input type="hidden" name="id" value={r?.id ?? ''} />
              <div className="grid grid-cols-3 gap-3">
                <Field label="Código" name="code" defaultValue={r?.code} className="col-span-2" placeholder="ex.: imperatriz" />
                <Field label="UF" name="uf" defaultValue={r?.uf ?? 'MA'} />
              </div>
              <Field label="Nome" name="name" defaultValue={r?.name} placeholder={r ? undefined : 'Nova região'} />
              <div className="grid grid-cols-3 gap-3">
                <Field label="Latitude" name="lat" inputMode="decimal" defaultValue={r?.center_lat} />
                <Field label="Longitude" name="lng" inputMode="decimal" defaultValue={r?.center_lng} />
                <Field label="Raio (km)" name="radius_km" inputMode="numeric" defaultValue={r?.radius_km ?? 30} />
              </div>
              <CheckboxField name="active" label="Ativa" defaultChecked={r?.active ?? true} />
              <CheckboxField name="is_default" label="Região padrão (pedido sem localização)" defaultChecked={r?.is_default ?? false} />
              <SubmitButton variant={r ? 'secondary' : 'primary'}>{r ? 'Salvar região' : 'Adicionar região'}</SubmitButton>
            </ActionForm>
          </Panel>
        ))}
      </div>

      <SectionTitle>Histórico de alterações</SectionTitle>
      <Panel>
        <Table>
          <thead><tr><th>Quando</th><th>Quem</th><th>O quê</th><th>Mudança</th></tr></thead>
          <tbody>
            {history.map((h) => (
              <tr key={h.id}>
                <td className="whitespace-nowrap">{formatDateTime(h.at)}</td>
                <td>{h.actor ?? 'sistema'}</td>
                <td>{entityLabel[h.entity] ?? h.entity}{h.after && 'name' in h.after ? `: ${h.after.name}` : ''}</td>
                <td className="text-muted-foreground">{changes(h)}</td>
              </tr>
            ))}
          </tbody>
        </Table>
      </Panel>
    </>
  )
}
