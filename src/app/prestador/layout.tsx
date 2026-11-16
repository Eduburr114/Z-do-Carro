import { AppShell } from '@/components/app/shell'
import { requireRole } from '@/lib/auth/session'

export default async function ProviderLayout({ children }: { children: React.ReactNode }) {
  await requireRole('provider')
  return (
    <AppShell
      area="Prestador"
      home="/prestador"
      nav={[
        { href: '/prestador', label: 'Início', icon: 'home', exact: true },
        { href: '/prestador/ganhos', label: 'Ganhos', icon: 'wallet' },
        { href: '/prestador/contrato', label: 'Contrato', icon: 'contract' },
      ]}
    >
      {children}
    </AppShell>
  )
}
