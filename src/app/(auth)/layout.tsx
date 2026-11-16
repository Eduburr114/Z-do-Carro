import Link from 'next/link'
import { Wordmark } from '@/components/app/brand'

export default function AuthLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-dvh">
      <header className="bg-nav pt-safe text-nav-foreground">
        <div className="mx-auto flex h-16 max-w-md items-center px-5">
          <Link href="/"><Wordmark className="text-xl" /></Link>
        </div>
      </header>
      <main className="mx-auto max-w-md px-5 py-8 has-[article]:max-w-2xl">{children}</main>
    </div>
  )
}
