import Link from 'next/link'
import { redirect } from 'next/navigation'
import { BadgeCheck, MapPin, ShieldCheck, Wallet } from 'lucide-react'
import { buttonVariants } from '@/components/ui/button'
import { WheelMark } from '@/components/app/brand'
import { getSession, homeFor } from '@/lib/auth/session'

const steps = [
  { icon: MapPin, title: 'Peça de onde estiver', text: 'Escolha o serviço, informe o carro e o endereço. O preço aparece antes de confirmar.' },
  { icon: BadgeCheck, title: 'Um prestador credenciado aceita', text: 'Todo profissional passa por análise técnica e documental da HUB antes de atender.' },
  { icon: Wallet, title: 'Acompanhe e pague pelo app', text: 'Serviço adicional só com o seu aceite. No fim, você paga e avalia.' },
]

export default async function Landing() {
  const session = await getSession()
  if (session) redirect(session.profile ? homeFor[session.profile.role] : '/completar')
  return (
    <div className="min-h-dvh bg-nav text-nav-foreground">
      <div className="mx-auto flex min-h-dvh max-w-xl flex-col px-5 pt-safe pb-safe">
        <header className="flex items-center justify-between py-5">
          <span className="flex items-center gap-2.5 font-display text-xl font-semibold">
            <WheelMark className="size-9 rounded-lg" />
            Zé do Carro
          </span>
          <Link href="/login" className="rounded-full px-3 py-2 text-sm font-semibold text-nav-foreground underline-offset-4 hover:underline">
            Entrar
          </Link>
        </header>

        <main className="flex flex-1 flex-col justify-center py-8">
          <p className="mb-4 w-fit rounded-full bg-brand px-3 py-1 text-sm font-bold text-brand-foreground">Serviço automotivo móvel</p>
          <h1 className="text-[2.6rem] leading-[1.02] font-semibold text-balance">O mecânico vai até o seu carro.</h1>
          <p className="mt-4 text-lg text-nav-muted">
            Troca de pneu, óleo, alinhamento, balanceamento e higienização, em casa, no trabalho ou na rua. Com preço na tela antes de pedir.
          </p>
          <div className="mt-8 flex flex-col gap-3">
            <Link href="/cadastro" className={buttonVariants({ size: 'lg', className: 'w-full' })}>
              Pedir um serviço
            </Link>
            <Link href="/cadastro?tipo=prestador" className={buttonVariants({ size: 'lg', variant: 'outline', className: 'w-full border-nav-muted/40 bg-transparent text-nav-foreground hover:bg-white/10' })}>
              Sou profissional e quero atender
            </Link>
          </div>

          <ol className="mt-12 space-y-5">
            {steps.map((step) => (
              <li key={step.title} className="flex gap-4">
                <span className="flex size-11 shrink-0 items-center justify-center rounded-full bg-white/10 text-brand">
                  <step.icon className="size-5" aria-hidden="true" />
                </span>
                <div>
                  <p className="font-semibold">{step.title}</p>
                  <p className="text-sm text-nav-muted">{step.text}</p>
                </div>
              </li>
            ))}
          </ol>
        </main>

        <footer className="flex items-center gap-2 py-6 text-sm text-nav-muted">
          <ShieldCheck className="size-4 shrink-0" aria-hidden="true" />
          HUB Tecnologia e Serviços Automotivos Ltda.
        </footer>
      </div>
    </div>
  )
}
