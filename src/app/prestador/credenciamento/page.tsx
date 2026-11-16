import type { Metadata } from 'next'
import { redirect } from 'next/navigation'
import { GeoFields } from '@/components/app/geo-fields'
import { ActionForm, CheckboxField, Field, SelectField, SubmitButton, TextareaField } from '@/components/ui/form'
import { Notice, Panel } from '@/components/ui/primitives'
import { SectionTitle } from '@/components/app/bits'
import { DocumentList } from '@/features/documents/list'
import { DocumentUploader } from '@/features/documents/uploader'
import { applyProvider } from '@/features/provider/actions'
import { requireRole } from '@/lib/auth/session'
import { formatMoney } from '@/lib/format'
import { rpc } from '@/lib/rpc'
import type { ProviderDocument, ProviderHome, Service } from '@/lib/types'

export const metadata: Metadata = { title: 'Credenciamento' }

export default async function ApplyPage() {
  const session = await requireRole('provider')
  const [home, services, documents] = await Promise.all([
    rpc<ProviderHome>('provider_home'),
    rpc<Service[]>('list_services'),
    rpc<ProviderDocument[]>('my_documents'),
  ])
  if (!['draft', 'rejected', 'closed'].includes(home.status)) redirect('/prestador')
  return (
    <>
      <h1 className="text-2xl font-semibold">Credenciamento</h1>
      <p className="mt-1 mb-5 text-muted-foreground">Estes dados identificam você no contrato e são analisados pela HUB.</p>
      <Notice tone="info" className="mb-5">
        Você atua como profissional autônomo ou empresa independente: escolhe quando ficar disponível, quais pedidos aceitar e pode atender outros clientes e plataformas.
      </Notice>
      <SectionTitle>1. Documentos</SectionTitle>
      <p className="mb-3 text-sm text-muted-foreground">
        Envie ao menos um documento de identificação com foto. Certificados e fotos dos equipamentos ajudam na análise técnica. Fotos ou PDF de até 3 MB.
      </p>
      <Panel>
        <DocumentList documents={documents} removable />
        <div className="border-t border-border px-4 py-4"><DocumentUploader /></div>
      </Panel>

      <SectionTitle>2. Seus dados e serviços</SectionTitle>
      <ActionForm action={applyProvider} redirectTo="/prestador" successMessage="Credenciamento enviado para análise." resetOnSuccess={false}>
        <div className="grid grid-cols-[7rem_1fr] gap-3">
          <SelectField label="Documento" name="doc_type" defaultValue="cpf">
            <option value="cpf">CPF</option>
            <option value="cnpj">CNPJ</option>
          </SelectField>
          <Field label="Número" name="doc_number" inputMode="numeric" required />
        </div>
        <Field label="Nome completo ou razão social" name="legal_name" defaultValue={home.legal_name ?? session.profile.full_name} required />
        <div className="grid grid-cols-[1fr_8rem] gap-3">
          <Field label="Cidade de atuação" name="city" defaultValue={home.city ?? 'São Luís'} required />
          <Field label="Raio (km)" name="radius_km" inputMode="numeric" defaultValue={String(home.radius_km)} required />
        </div>
        <GeoFields label="Marcar meu ponto de partida" hint="Opcional. Usado para mostrar só pedidos dentro do seu raio." />
        <fieldset className="space-y-3">
          <legend className="mb-2 block text-sm font-semibold">Serviços que você executa</legend>
          {services.map((service) => (
            <CheckboxField key={service.id} name="service_ids[]" value={service.id} label={service.name} hint={`Preço ao cliente: ${formatMoney(service.base_price)}`} />
          ))}
        </fieldset>
        <TextareaField label="Experiência, certificações e equipamentos" name="experience" rows={4} hint="Conte há quanto tempo atua e o que você tem para atender em campo." />
        <SubmitButton size="lg" className="w-full">Enviar para análise</SubmitButton>
      </ActionForm>
    </>
  )
}
