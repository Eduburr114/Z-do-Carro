import { AppShell } from '@/components/app/shell'
import { requireRole } from '@/lib/auth/session'

export default async function HubLayout({ children }: { children: React.ReactNode }) {
  await requireRole('hub_admin')
  return (
    <AppShell
      wide
      area="HUB"
      home="/hub"
      nav={[
        { href: '/hub', label: 'Visão geral', icon: 'gauge', exact: true },
        { href: '/hub/prestadores', label: 'Prestadores', icon: 'people' },
        { href: '/hub/pedidos', label: 'Pedidos', icon: 'orders' },
        { href: '/hub/ajustes', label: 'Ajustes', icon: 'settings' },
      ]}
    >
      {children}
    </AppShell>
  )
}
