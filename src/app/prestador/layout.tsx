import { AppShell } from '@/components/app/shell'
import { requireRole } from '@/lib/auth/session'

export default async function ProviderLayout({ children }: { children: React.ReactNode }) {
  const session = await requireRole('provider')
  return <AppShell session={session}>{children}</AppShell>
}
