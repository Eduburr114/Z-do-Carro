import type { ReactNode } from 'react'
import Link from 'next/link'
import { Wordmark } from './brand'

/** Página simples com a barra da marca, para telas fora das três áreas. */
export function PlainPage({ children, wide }: { children: ReactNode; wide?: boolean }) {
  return (
    <div className="min-h-dvh">
      <header className="bg-nav pt-safe text-nav-foreground">
        <div className={`mx-auto flex h-16 items-center px-5 ${wide ? 'max-w-2xl' : 'max-w-md'}`}>
          <Link href="/"><Wordmark className="text-xl" /></Link>
        </div>
      </header>
      <main className={`mx-auto px-5 py-8 ${wide ? 'max-w-2xl' : 'max-w-md'}`}>{children}</main>
    </div>
  )
}
