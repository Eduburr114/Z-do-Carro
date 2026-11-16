import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { GeoFields } from '@/components/app/geo-fields'
import { Row } from '@/components/app/bits'
import { ActionForm, Field, SelectField, SubmitButton, TextareaField } from '@/components/ui/form'
import { Notice, Panel } from '@/components/ui/primitives'
import { buttonVariants } from '@/components/ui/button'
import { createRequest } from '@/features/customer/actions'
import { requireRole } from '@/lib/auth/session'
import { formatMoney } from '@/lib/format'
import { rpc } from '@/lib/rpc'
import type { Service, Vehicle } from '@/lib/types'

export const metadata: Metadata = { title: 'Pedir serviço' }

export default async function NewRequestPage({ params }: { params: Promise<{ id: string }> }) {
  await requireRole('customer')
  const { id } = await params
  const [services, vehicles] = await Promise.all([rpc<Service[]>('list_services'), rpc<Vehicle[]>('list_vehicles')])
  const service = services.find((s) => s.id === id)
  if (!service) notFound()
  return (
    <>
      <h1 className="text-2xl font-semibold">{service.name}</h1>
      <p className="mt-1 mb-5 text-muted-foreground">{service.description}</p>
      {vehicles.length === 0 ? (
        <Notice tone="info" title="Cadastre o seu veículo primeiro">
          <p>O prestador precisa saber qual carro vai atender.</p>
          <Link href="/cliente/veiculos" className={buttonVariants({ className: 'mt-3' })}>Cadastrar veículo</Link>
        </Notice>
      ) : (
        <ActionForm action={createRequest} resetOnSuccess={false}>
          <input type="hidden" name="service_id" value={service.id} />
          <SelectField label="Veículo" name="vehicle_id" defaultValue={vehicles[0].id}>
            {vehicles.map((vehicle) => (
              <option key={vehicle.id} value={vehicle.id}>
                {vehicle.brand} {vehicle.model} · {vehicle.plate}
              </option>
            ))}
          </SelectField>
          <Field label="Onde o carro está?" name="address" autoComplete="street-address" placeholder="Rua, número, bairro e ponto de referência" required />
          <GeoFields hint="Opcional. Ajuda a encontrar o prestador mais próximo." />
          <TextareaField label="Observações" name="notes" hint="Opcional. Ex.: medida do pneu, portaria, melhor horário." />
          <Panel className="px-4 py-3">
            <Row label={service.name} value={formatMoney(service.base_price)} />
            <Row label="Duração estimada" value={`${service.est_minutes} min`} />
            <div className="my-1.5 border-t border-border" />
            <Row label="Total" value={formatMoney(service.base_price)} strong />
            <p className="mt-1 text-sm text-muted-foreground">Você paga só depois do serviço. Qualquer adicional precisa da sua aprovação no aplicativo.</p>
          </Panel>
          <SubmitButton size="lg" className="w-full">Confirmar pedido</SubmitButton>
        </ActionForm>
      )}
    </>
  )
}
