import type { Metadata } from 'next'
import Link from 'next/link'
import { ChevronRight } from 'lucide-react'
import { RatingBadge } from '@/components/app/bits'
import { Badge, Empty, Panel } from '@/components/ui/primitives'
import { requireStaff } from '@/lib/auth/session'
import { formatDate, providerStatus } from '@/lib/format'
import { rpc } from '@/lib/rpc'
import type { ProviderStatus, Rating } from '@/lib/types'

export const metadata: Metadata = { title: 'Prestadores' }

type Row = {
  id: string; name: string; legal_name: string | null; city: string | null; status: ProviderStatus; online: boolean
  applied_at: string | null; contract_ok: boolean; rating: Rating; completed: number; contested: boolean
}

export default async function ProvidersPage() {
  await requireStaff('admin')
  const providers = await rpc<Row[]>('admin_providers')
  return (
    <>
      <h1 className="mb-4 text-2xl font-semibold">Prestadores</h1>
      <Panel>
        {providers.length === 0 ? (
          <Empty title="Nenhum credenciamento enviado ainda" />
        ) : (
          <ul className="divide-y divide-border">
            {providers.map((p) => (
              <li key={p.id}>
                <Link href={`/hub/prestadores/${p.id}`} className="flex items-center gap-3 px-4 py-3.5 hover:bg-surface-2/60">
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="font-semibold">{p.legal_name ?? p.name}</p>
                      <Badge tone={providerStatus[p.status].tone}>{providerStatus[p.status].label}</Badge>
                      {p.contested ? <Badge tone="warning">Contestação</Badge> : null}
                      {p.status === 'approved' && !p.contract_ok ? <Badge tone="neutral">Sem contrato aceito</Badge> : null}
                      {p.online ? <Badge tone="success">Disponível</Badge> : null}
                    </div>
                    <p className="mt-0.5 text-sm text-muted-foreground">
                      {p.city ?? '—'} · enviado em {formatDate(p.applied_at)} · {p.completed} atendimento(s)
                    </p>
                  </div>
                  <span className="hidden sm:block"><RatingBadge rating={p.rating} /></span>
                  <ChevronRight className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
                </Link>
              </li>
            ))}
          </ul>
        )}
      </Panel>
    </>
  )
}
