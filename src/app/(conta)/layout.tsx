import { AppShell } from '@/components/app/shell'
import { requireUser } from '@/lib/auth/session'

/** Telas comuns aos três papéis (conta e avisos), com a moldura da área de cada um. */
export default async function AccountLayout({ children }: { children: React.ReactNode }) {
  const session = await requireUser()
  return <AppShell session={session}>{children}</AppShell>
}
