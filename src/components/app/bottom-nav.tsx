'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { Car, CircleUser, ClipboardList, FileText, Gauge, House, Settings, Users, Wallet } from 'lucide-react'

const icons = { home: House, orders: ClipboardList, car: Car, wallet: Wallet, contract: FileText, people: Users, settings: Settings, gauge: Gauge, user: CircleUser }

export type NavItem = { href: string; label: string; icon: keyof typeof icons; exact?: boolean }

export function BottomNav({ items }: { items: NavItem[] }) {
  const pathname = usePathname()
  return (
    <nav aria-label="Principal" className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-surface pb-safe">
      <ul className="mx-auto flex max-w-xl">
        {items.map((item) => {
          const active = item.exact ? pathname === item.href : pathname === item.href || pathname.startsWith(`${item.href}/`)
          const Icon = icons[item.icon]
          return (
            <li key={item.href} className="flex-1">
              <Link
                href={item.href}
                aria-current={active ? 'page' : undefined}
                className={`flex h-16 flex-col items-center justify-center gap-1 text-[0.7rem] font-semibold ${active ? 'text-foreground' : 'text-muted-foreground'}`}
              >
                <span className={`flex h-7 w-12 items-center justify-center rounded-full ${active ? 'bg-brand text-brand-foreground' : ''}`}>
                  <Icon className="size-5" />
                </span>
                {item.label}
              </Link>
            </li>
          )
        })}
      </ul>
    </nav>
  )
}
