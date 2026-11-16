import Link from 'next/link'
import { buttonVariants } from '@/components/ui/button'

export default function NotFound() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-md flex-col items-center justify-center px-5 text-center">
      <h1 className="text-2xl font-semibold">Página não encontrada</h1>
      <p className="mt-2 text-muted-foreground">O endereço não existe ou você não tem acesso a ele.</p>
      <Link href="/" className={buttonVariants({ className: 'mt-6' })}>Voltar ao início</Link>
    </main>
  )
}
