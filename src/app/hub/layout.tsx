import { AppShell } from '@/components/app/shell'
import { requireRole } from '@/lib/auth/session'

export default async function HubLayout({ children }: { children: React.ReactNode }) {
  const session = await requireRole('hub_admin')
  return <AppShell session={session}>{children}</AppShell>
}
