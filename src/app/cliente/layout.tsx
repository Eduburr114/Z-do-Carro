import { AppShell } from '@/components/app/shell'
import { requireRole } from '@/lib/auth/session'

export default async function CustomerLayout({ children }: { children: React.ReactNode }) {
  const session = await requireRole('customer')
  return <AppShell session={session}>{children}</AppShell>
}
