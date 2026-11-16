import type { ReactNode } from 'react'
import Link from 'next/link'
import { LogOut } from 'lucide-react'
import { signOut } from '@/features/auth/actions'
import { WheelMark } from './brand'
import { BottomNav, type NavItem } from './bottom-nav'

/** Moldura das três áreas: barra superior, conteúdo em coluna de celular e abas embaixo. */
export function AppShell({ area, home, nav, children, wide }: { area: string; home: string; nav: NavItem[]; children: ReactNode; wide?: boolean }) {
  return (
    <div className="flex min-h-dvh flex-col">
      <header className="sticky top-0 z-20 bg-nav pt-safe text-nav-foreground">
        <div className={`mx-auto flex h-14 items-center justify-between gap-3 px-4 ${wide ? 'max-w-4xl' : 'max-w-xl'}`}>
          <Link href={home} className="flex items-center gap-2.5 font-display text-lg font-semibold">
            <WheelMark className="size-8 rounded-lg" />
            <span>Zé do Carro</span>
            <span className="rounded-full bg-brand px-2 py-0.5 font-sans text-xs font-bold text-brand-foreground">{area}</span>
          </Link>
          <form action={signOut}>
            <button type="submit" className="flex size-11 items-center justify-center rounded-full text-nav-muted hover:text-nav-foreground" aria-label="Sair da conta">
              <LogOut className="size-5" />
            </button>
          </form>
        </div>
      </header>
      <main className={`mx-auto w-full flex-1 px-4 pt-5 pb-28 ${wide ? 'max-w-4xl' : 'max-w-xl'}`}>{children}</main>
      <BottomNav items={nav} />
    </div>
  )
}
