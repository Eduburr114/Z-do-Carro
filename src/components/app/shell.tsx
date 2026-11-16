import type { ReactNode } from 'react'
import Link from 'next/link'
import { Bell } from 'lucide-react'
import type { ActiveSession } from '@/lib/auth/session'
import { WheelMark } from './brand'
import { BottomNav } from './bottom-nav'
import { areaOf } from './nav'

/** Moldura das três áreas: barra superior com os avisos, conteúdo em coluna de celular e abas embaixo. */
export function AppShell({ session, children }: { session: ActiveSession; children: ReactNode }) {
  const area = areaOf[session.profile.role]
  const width = area.wide ? 'max-w-4xl' : 'max-w-xl'
  return (
    <div className="flex min-h-dvh flex-col">
      <header className="sticky top-0 z-20 bg-nav pt-safe text-nav-foreground">
        <div className={`mx-auto flex h-14 items-center justify-between gap-3 px-4 ${width}`}>
          <Link href={area.home} className="flex items-center gap-2.5 font-display text-lg font-semibold">
            <WheelMark className="size-8 rounded-lg" />
            <span>Zé do Carro</span>
            <span className="rounded-full bg-brand px-2 py-0.5 font-sans text-xs font-bold text-brand-foreground">{area.label}</span>
          </Link>
          <Link
            href="/avisos"
            className="relative flex size-11 items-center justify-center rounded-full text-nav-foreground hover:bg-white/10"
            aria-label={session.unread > 0 ? `Avisos: ${session.unread} não lidos` : 'Avisos'}
          >
            <Bell className="size-5" />
            {session.unread > 0 ? (
              <span className="absolute top-1.5 right-1.5 flex h-4.5 min-w-4.5 items-center justify-center rounded-full bg-brand px-1 text-[0.65rem] font-bold text-brand-foreground">
                {session.unread > 9 ? '9+' : session.unread}
              </span>
            ) : null}
          </Link>
        </div>
      </header>
      <main className={`mx-auto w-full flex-1 px-4 pt-5 pb-28 ${width}`}>{children}</main>
      <BottomNav items={area.nav} />
    </div>
  )
}
