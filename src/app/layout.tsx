import type { Metadata, Viewport } from 'next'
import { headers } from 'next/headers'
import { Toaster } from 'sonner'
import '@fontsource-variable/figtree'
import '@fontsource-variable/bricolage-grotesque'
import { isConfigured } from '@/lib/env'
import './globals.css'

export const metadata: Metadata = {
  title: { default: 'Zé do Carro', template: '%s — Zé do Carro' },
  description: 'Serviços automotivos onde o seu carro estiver: troca de pneu, óleo, alinhamento, balanceamento e higienização.',
  applicationName: 'Zé do Carro',
  appleWebApp: { capable: true, title: 'Zé do Carro', statusBarStyle: 'default' },
  icons: { icon: '/icons/icon.svg', apple: '/icons/apple-touch-icon.png' },
  formatDetection: { telephone: false },
}

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  viewportFit: 'cover',
  themeColor: '#10151f',
}

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  // Ler o cabeçalho torna toda página dinâmica: os scripts recebem o nonce da
  // Content-Security-Policy definida em src/proxy.ts a cada requisição.
  await headers()
  return (
    <html lang="pt-BR">
      <body className="min-h-dvh antialiased">
        {isConfigured() ? (
          children
        ) : (
          <main className="mx-auto flex min-h-dvh max-w-md flex-col items-center justify-center px-5 text-center">
            <h1 className="text-2xl font-semibold">Zé do Carro em configuração</h1>
            <p className="mt-2 text-muted-foreground">O aplicativo foi publicado, mas ainda não está ligado ao banco de dados. Volte em breve.</p>
          </main>
        )}
        <Toaster position="top-center" richColors closeButton />
      </body>
    </html>
  )
}
