import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'
import { sessionCookieOptions } from '@/lib/supabase/cookie-options'

/**
 * Proxy (antigo middleware): roda antes de cada página.
 *  1. Renova a sessão do Supabase e regrava os cookies.
 *  2. Manda quem não está autenticado para o login.
 *  3. Define a Content-Security-Policy com nonce por requisição.
 *
 * Não é a barreira de autorização: cada página e cada Server Action conferem a
 * sessão de novo, e o banco decide por último (RLS e funções).
 */

// /api/webhooks e /api/cron não usam sessão: autenticam por token próprio.
const PUBLIC_PREFIXES = ['/login', '/cadastro', '/recuperar', '/auth', '/termos', '/privacidade', '/api/webhooks', '/api/cron']

function buildCsp(nonce: string): string {
  const isDev = process.env.NODE_ENV !== 'production'
  return [
    `default-src 'self'`,
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${isDev ? ` 'unsafe-eval'` : ''}`,
    `style-src 'self' 'unsafe-inline'`,
    // Os quadros do mapa vêm do OpenStreetMap.
    `img-src 'self' data: blob: https://tile.openstreetmap.org`,
    `font-src 'self'`,
    `connect-src 'self'${isDev ? ' ws: wss:' : ''}`,
    `worker-src 'self'`,
    `manifest-src 'self'`,
    `object-src 'none'`,
    `base-uri 'self'`,
    `form-action 'self'`,
    `frame-ancestors 'none'`,
    ...(isDev ? [] : ['upgrade-insecure-requests']),
  ].join('; ')
}

export async function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl
  const nonce = Buffer.from(crypto.randomUUID()).toString('base64')
  const csp = buildCsp(nonce)

  const requestHeaders = new Headers(request.headers)
  requestHeaders.set('x-nonce', nonce)
  requestHeaders.set('Content-Security-Policy', csp)

  let response = NextResponse.next({ request: { headers: requestHeaders } })

  // Publicação ainda sem banco configurado: o layout mostra um aviso (ver src/lib/env.ts).
  if (!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY) {
    response.headers.set('Content-Security-Policy', csp)
    return response
  }

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    {
      cookieOptions: sessionCookieOptions,
      cookies: {
        getAll() {
          return request.cookies.getAll()
        },
        setAll(cookiesToSet) {
          for (const { name, value } of cookiesToSet) request.cookies.set(name, value)
          response = NextResponse.next({ request: { headers: requestHeaders } })
          for (const { name, value, options } of cookiesToSet) {
            response.cookies.set(name, value, { ...options, ...sessionCookieOptions })
          }
        },
      },
    },
  )

  // getClaims valida o JWT (e renova o token vencido usando o refresh token).
  const { data } = await supabase.auth.getClaims()
  const authenticated = Boolean(data?.claims?.sub)

  const finish = (result: NextResponse) => {
    if (result !== response) {
      for (const cookie of response.cookies.getAll()) result.cookies.set(cookie)
    }
    result.headers.set('Content-Security-Policy', csp)
    return result
  }

  const isPublic = pathname === '/' || PUBLIC_PREFIXES.some((prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`))
  const isServerAction = request.method === 'POST' && request.headers.has('next-action')

  if (!authenticated && !isPublic && !isServerAction) {
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    url.search = ''
    return finish(NextResponse.redirect(url))
  }
  if (authenticated && (pathname === '/login' || pathname === '/cadastro')) {
    const url = request.nextUrl.clone()
    url.pathname = '/'
    url.search = ''
    return finish(NextResponse.redirect(url))
  }
  return finish(response)
}

export const config = {
  matcher: [
    // Tudo, exceto arquivos estáticos e os ícones do PWA.
    '/((?!_next/static|_next/image|favicon.ico|sw.js|manifest.webmanifest|icons/).*)',
  ],
}
