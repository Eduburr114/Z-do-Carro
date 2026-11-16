import { AppShell } from '@/components/app/shell'
import { requireRole } from '@/lib/auth/session'

export default async function CustomerLayout({ children }: { children: React.ReactNode }) {
  await requireRole('customer')
  return (
    <AppShell
      area="Cliente"
      home="/cliente"
      nav={[
        { href: '/cliente', label: 'Início', icon: 'home', exact: true },
        { href: '/cliente/pedidos', label: 'Pedidos', icon: 'orders' },
        { href: '/cliente/veiculos', label: 'Veículos', icon: 'car' },
      ]}
    >
      {children}
    </AppShell>
  )
}
