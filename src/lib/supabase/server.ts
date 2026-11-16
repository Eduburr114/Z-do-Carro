import 'server-only'
import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import { env } from '@/lib/env'
import { sessionCookieOptions } from '@/lib/supabase/cookie-options'

/** Cliente do Supabase com a sessão do usuário (JWT próprio; o RLS se aplica). */
export async function createClient() {
  const cookieStore = await cookies()
  const config = env()
  return createServerClient(config.NEXT_PUBLIC_SUPABASE_URL, config.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, {
    cookieOptions: sessionCookieOptions,
    cookies: {
      getAll() {
        return cookieStore.getAll()
      },
      setAll(cookiesToSet) {
        try {
          for (const { name, value, options } of cookiesToSet) {
            cookieStore.set(name, value, { ...options, ...sessionCookieOptions })
          }
        } catch {
          // Em Server Components os cookies são somente leitura; a renovação da
          // sessão acontece no proxy (src/proxy.ts).
        }
      },
    },
  })
}
