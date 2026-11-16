import type { Metadata } from 'next'
import Link from 'next/link'
import { Empty, Panel } from '@/components/ui/primitives'
import { requireUser } from '@/lib/auth/session'
import { formatDateTime } from '@/lib/format'
import { rpc } from '@/lib/rpc'

export const metadata: Metadata = { title: 'Avisos' }

type Item = { id: number; title: string; body: string; url: string; created_at: string; unread: boolean }

export default async function NotificationsPage() {
  await requireUser()
  // Abrir a lista marca os avisos como lidos.
  const items = await rpc<Item[]>('my_notifications')
  return (
    <>
      <h1 className="mb-4 text-2xl font-semibold">Avisos</h1>
      <Panel>
        {items.length === 0 ? (
          <Empty title="Nenhum aviso ainda">Novidades dos seus pedidos aparecem aqui.</Empty>
        ) : (
          <ul className="divide-y divide-border">
            {items.map((item) => (
              <li key={item.id}>
                <Link href={item.url} className="flex gap-3 px-4 py-3.5 hover:bg-surface-2/60">
                  <span className={`mt-1.5 size-2.5 shrink-0 rounded-full ${item.unread ? 'bg-brand' : 'bg-transparent'}`} aria-hidden="true" />
                  <span className="min-w-0 flex-1">
                    <span className="block font-semibold">{item.title}{item.unread ? <span className="sr-only"> (novo)</span> : null}</span>
                    <span className="block text-sm text-muted-foreground">{item.body}</span>
                    <span className="mt-0.5 block text-xs text-muted-foreground">{formatDateTime(item.created_at)}</span>
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </Panel>
    </>
  )
}
