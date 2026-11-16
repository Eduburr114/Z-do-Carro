import type { Metadata } from 'next'
import { SectionTitle } from '@/components/app/bits'
import { ActionForm, SubmitButton } from '@/components/ui/form'
import { Badge, PageHeader, Panel } from '@/components/ui/primitives'
import { setStaffRole } from '@/features/hub/actions'
import { SetupCode } from '@/features/hub/setup-code'
import { SettingsTabs } from '@/features/hub/tabs'
import { requireStaff } from '@/lib/auth/session'
import { rpc } from '@/lib/rpc'

export const metadata: Metadata = { title: 'Equipe' }

type Staff = { id: string; name: string; roles: ('admin' | 'finance')[] }
const roleLabel = { admin: 'Administração', finance: 'Financeiro' } as const

export default async function TeamPage() {
  const session = await requireStaff('admin')
  const [staff, { settings }] = await Promise.all([
    rpc<Staff[]>('admin_staff'),
    rpc<{ settings: { setup_code_pending: boolean } }>('admin_overview'),
  ])
  return (
    <>
      <PageHeader title="Ajustes" />
      <SettingsTabs current="/hub/ajustes/equipe" />
      <p className="mb-3 text-sm text-muted-foreground">
        Separe as funções: a administração cuida de credenciamento, catálogo e comissões; o financeiro, de pagamentos, repasses, estornos e contas Pix. Toda mudança fica na auditoria.
      </p>
      <Panel>
        <ul className="divide-y divide-border">
          {staff.map((person) => (
            <li key={person.id} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
              <div>
                <p className="font-semibold">{person.name}{person.id === session.userId ? ' (você)' : ''}</p>
                <div className="mt-1 flex gap-1">
                  {person.roles.length ? person.roles.map((r) => <Badge key={r} tone="info">{roleLabel[r]}</Badge>) : <Badge>Sem papel</Badge>}
                </div>
              </div>
              <div className="flex flex-wrap gap-2">
                {(['admin', 'finance'] as const).map((role) => {
                  const has = person.roles.includes(role)
                  return (
                    <ActionForm key={role} action={setStaffRole} successMessage="Papel atualizado.">
                      <input type="hidden" name="user_id" value={person.id} />
                      <input type="hidden" name="role" value={role} />
                      <input type="hidden" name="grant" value={has ? 'no' : 'yes'} />
                      <SubmitButton size="sm" variant="outline">{has ? `Tirar ${roleLabel[role].toLowerCase()}` : `Dar ${roleLabel[role].toLowerCase()}`}</SubmitButton>
                    </ActionForm>
                  )
                })}
              </div>
            </li>
          ))}
        </ul>
      </Panel>
      <SectionTitle>Novo acesso da equipe</SectionTitle>
      <Panel className="px-4 py-4">
        <SetupCode pending={settings.setup_code_pending} />
      </Panel>
    </>
  )
}
