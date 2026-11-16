import type { Metadata } from 'next'
import { SectionTitle } from '@/components/app/bits'
import { ActionForm, CheckboxField, Field, MoneyField, SelectField, SubmitButton } from '@/components/ui/form'
import { Badge, Empty, PageHeader, Panel } from '@/components/ui/primitives'
import { createCommissionRule, endCommissionRule, savePromotion } from '@/features/hub/actions'
import { SettingsTabs } from '@/features/hub/tabs'
import { requireStaff } from '@/lib/auth/session'
import { formatDateTime, formatMoney, formatPercent } from '@/lib/format'
import { requestTime } from '@/lib/clock'
import { rpc } from '@/lib/rpc'
import type { Catalog } from '../catalogo/page'

export const metadata: Metadata = { title: 'Comissões e promoções' }

const scopeLabel = { category: 'Categoria', provider: 'Prestador', campaign: 'Campanha' } as const
/** ISO para o campo datetime-local, no horário de Brasília. */
const local = (iso: string | null) => (iso ? new Date(new Date(iso).getTime() - 3 * 3600_000).toISOString().slice(0, 16) : '')

export default async function CommissionsPage() {
  await requireStaff('admin')
  const c = await rpc<Catalog>('admin_catalog')
  const categoryName = (code: string | null) => c.categories.find((x) => x.code === code)?.name ?? 'todas'
  const t = requestTime()
  const now = new Date(t).toISOString()
  const inAMonth = new Date(t + 30 * 86400_000).toISOString()
  return (
    <>
      <PageHeader title="Ajustes" />
      <SettingsTabs current="/hub/ajustes/comissoes" />

      <SectionTitle>Regras de comissão</SectionTitle>
      <p className="mb-3 text-sm text-muted-foreground">
        Prioridade: prestador, depois campanha, depois categoria, depois a comissão padrão. Uma regra não se edita: encerre e crie outra. Pedidos já criados mantêm a comissão registrada.
      </p>
      <Panel>
        {c.commission_rules.length === 0 ? <Empty title="Nenhuma regra além da comissão padrão" /> : (
          <ul className="divide-y divide-border">
            {c.commission_rules.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
                <div className="min-w-0">
                  <p className="font-semibold">{r.name} · {formatPercent(r.percent)}</p>
                  <p className="text-sm text-muted-foreground">
                    {scopeLabel[r.scope]}: {r.scope === 'provider' ? r.provider_name : r.scope === 'category' ? categoryName(r.category_code) : `categoria ${categoryName(r.category_code)}`}
                    {r.starts_at ? ` · de ${formatDateTime(r.starts_at)}` : ''}{r.ends_at ? ` até ${formatDateTime(r.ends_at)}` : ''}
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <Badge tone={r.running ? 'success' : 'neutral'}>{r.running ? 'Vigente' : r.active ? 'Agendada' : 'Encerrada'}</Badge>
                  {r.active ? (
                    <ActionForm action={endCommissionRule} successMessage="Regra encerrada.">
                      <input type="hidden" name="id" value={r.id} />
                      <SubmitButton size="sm" variant="outline">Encerrar</SubmitButton>
                    </ActionForm>
                  ) : null}
                </div>
              </li>
            ))}
          </ul>
        )}
      </Panel>
      <Panel className="mt-3 px-4 py-4">
        <h3 className="mb-3 font-semibold">Nova regra</h3>
        <ActionForm action={createCommissionRule} successMessage="Regra criada.">
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="Nome" name="name" placeholder="ex.: Parceiro fundador" required />
            <Field label="Comissão (%)" name="percent" inputMode="decimal" required />
            <SelectField label="Tipo" name="scope" defaultValue="category">
              <option value="category">Por categoria</option>
              <option value="provider">Por prestador</option>
              <option value="campaign">Campanha (período)</option>
            </SelectField>
            <SelectField label="Categoria" name="category_code" defaultValue="" hint="Obrigatória para regra por categoria.">
              <option value="">Todas</option>
              {c.categories.map((x) => <option key={x.code} value={x.code}>{x.name}</option>)}
            </SelectField>
            <SelectField label="Prestador" name="provider_id" defaultValue="" hint="Só para regra por prestador.">
              <option value="">—</option>
              {c.providers.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </SelectField>
            <div />
            <Field label="Início (horário de Brasília)" name="starts_at" type="datetime-local" hint="Em branco: agora." />
            <Field label="Fim" name="ends_at" type="datetime-local" hint="Obrigatório para campanha." />
          </div>
          <SubmitButton>Criar regra</SubmitButton>
        </ActionForm>
      </Panel>

      <SectionTitle>Promoções</SectionTitle>
      <p className="mb-3 text-sm text-muted-foreground">
        Desconto automático, mostrado ao cliente antes de pagar e custeado pela HUB: o líquido do prestador não muda. Vale o maior desconto aplicável.
      </p>
      <div className="grid gap-3 sm:grid-cols-2">
        {[...c.promotions, null].map((p) => (
          <Panel key={p?.id ?? 'nova'} className="px-4 py-4">
            <div className="mb-2 flex items-center justify-between gap-2">
              <h3 className="font-semibold">{p ? p.name : 'Nova promoção'}</h3>
              {p ? <Badge tone={p.running ? 'success' : 'neutral'}>{p.running ? `Vigente · ${p.redemptions} uso(s)` : 'Fora do período'}</Badge> : null}
            </div>
            <ActionForm action={savePromotion} successMessage="Promoção salva." resetOnSuccess={!p}>
              <input type="hidden" name="id" value={p?.id ?? ''} />
              <Field label="Nome" name="name" defaultValue={p?.name} required />
              <div className="grid grid-cols-2 gap-3">
                <SelectField label="Tipo" name="kind" defaultValue={p?.kind ?? 'percent'}>
                  <option value="percent">Percentual (%)</option>
                  <option value="fixed">Valor fixo (R$)</option>
                </SelectField>
                <MoneyField label="Desconto" name="value" defaultValue={p ? String(p.value).replace('.', ',') : ''} />
                <SelectField label="Serviço" name="service_id" defaultValue={p?.service_id ?? ''}>
                  <option value="">Todos</option>
                  {c.services.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                </SelectField>
                <SelectField label="Categoria" name="category_code" defaultValue={p?.category_code ?? ''}>
                  <option value="">Todas</option>
                  {c.categories.map((x) => <option key={x.code} value={x.code}>{x.name}</option>)}
                </SelectField>
                <SelectField label="Região" name="region_id" defaultValue={p?.region_id ?? ''}>
                  <option value="">Todas</option>
                  {c.regions.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
                </SelectField>
                <Field label="Limite de usos" name="max_redemptions" inputMode="numeric" defaultValue={p?.max_redemptions ?? ''} hint="Em branco: sem limite." />
                <Field label="Início" name="starts_at" type="datetime-local" defaultValue={local(p?.starts_at ?? now)} />
                <Field label="Fim" name="ends_at" type="datetime-local" defaultValue={local(p?.ends_at ?? inAMonth)} />
              </div>
              <CheckboxField name="active" label="Ativa" defaultChecked={p?.active ?? true} />
              <SubmitButton variant={p ? 'secondary' : 'primary'}>{p ? 'Salvar' : 'Criar promoção'}</SubmitButton>
            </ActionForm>
            {p ? <p className="mt-2 text-xs text-muted-foreground">Exemplo: num serviço de {formatMoney(100)}, o cliente paga {formatMoney(p.kind === 'percent' ? 100 - p.value : Math.max(0, 100 - p.value))}.</p> : null}
          </Panel>
        ))}
      </div>
    </>
  )
}
