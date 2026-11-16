/**
 * Opções dos cookies de sessão. httpOnly: o JavaScript da página não lê os
 * tokens, o que limita o estrago de um eventual XSS. Em contrapartida, não há
 * cliente Supabase no navegador; tudo passa pelo servidor.
 */
export const sessionCookieOptions = {
  httpOnly: true,
  secure: process.env.NODE_ENV === 'production',
  sameSite: 'lax' as const,
  path: '/',
  maxAge: 60 * 60 * 24 * 30,
}
