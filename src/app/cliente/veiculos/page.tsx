import type { Metadata } from 'next'
import { SectionTitle } from '@/components/app/bits'
import { ActionForm, Field, SubmitButton } from '@/components/ui/form'
import { Empty, Panel } from '@/components/ui/primitives'
import { archiveVehicle, saveVehicle } from '@/features/customer/actions'
import { requireRole } from '@/lib/auth/session'
import { rpc } from '@/lib/rpc'
import type { Vehicle } from '@/lib/types'

export const metadata: Metadata = { title: 'Veículos' }

export default async function VehiclesPage() {
  await requireRole('customer')
  const vehicles = await rpc<Vehicle[]>('list_vehicles')
  return (
    <>
      <h1 className="mb-4 text-2xl font-semibold">Seus veículos</h1>
      <Panel>
        {vehicles.length === 0 ? (
          <Empty title="Nenhum veículo cadastrado">Cadastre abaixo para pedir o primeiro serviço.</Empty>
        ) : (
          <ul className="divide-y divide-border">
            {vehicles.map((vehicle) => (
              <li key={vehicle.id} className="flex items-center gap-3 px-4 py-3">
                <div className="min-w-0 flex-1">
                  <p className="font-semibold">{vehicle.brand} {vehicle.model}</p>
                  <p className="text-sm text-muted-foreground">{vehicle.plate}{vehicle.year ? ` · ${vehicle.year}` : ''}</p>
                </div>
                <ActionForm action={archiveVehicle} successMessage="Veículo removido.">
                  <input type="hidden" name="id" value={vehicle.id} />
                  <SubmitButton variant="ghost" size="sm">Remover</SubmitButton>
                </ActionForm>
              </li>
            ))}
          </ul>
        )}
      </Panel>

      <SectionTitle>Adicionar veículo</SectionTitle>
      <ActionForm action={saveVehicle} successMessage="Veículo cadastrado.">
        <Field label="Placa" name="plate" autoCapitalize="characters" placeholder="ABC1D23" maxLength={8} required />
        <div className="grid grid-cols-2 gap-3">
          <Field label="Marca" name="brand" placeholder="Fiat" required />
          <Field label="Modelo" name="model" placeholder="Argo" required />
        </div>
        <Field label="Ano" name="year" inputMode="numeric" placeholder="2021" maxLength={4} required />
        <SubmitButton className="w-full">Salvar veículo</SubmitButton>
      </ActionForm>
    </>
  )
}
