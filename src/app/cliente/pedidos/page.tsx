import type { Metadata } from 'next'
import { Empty, Panel } from '@/components/ui/primitives'
import { RequestCard } from '@/features/requests/components'
import { requireRole } from '@/lib/auth/session'
import { rpc } from '@/lib/rpc'
import type { ServiceRequest } from '@/lib/types'

export const metadata: Metadata = { title: 'Pedidos' }

export default async function RequestsPage() {
  await requireRole('customer')
  const requests = await rpc<ServiceRequest[]>('my_requests')
  return (
    <>
      <h1 className="mb-4 text-2xl font-semibold">Seus pedidos</h1>
      {requests.length === 0 ? (
        <Panel><Empty title="Nenhum pedido ainda">Escolha um serviço na tela inicial para começar.</Empty></Panel>
      ) : (
        <div className="space-y-2">
          {requests.map((request) => (
            <RequestCard key={request.id} request={request} href={`/cliente/pedidos/${request.id}`} amount={request.total} />
          ))}
        </div>
      )}
    </>
  )
}
