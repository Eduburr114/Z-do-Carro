import 'server-only'
import { z } from 'zod'

const schema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z.url(),
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: z.string().min(10),
  // Chave secreta: usada só no servidor, para o limite de tentativas e a fila de push.
  SUPABASE_SECRET_KEY: z.string().min(10),
  // Push (opcional): sem as chaves VAPID os avisos ficam só dentro do aplicativo.
  NEXT_PUBLIC_VAPID_PUBLIC_KEY: z.string().optional(),
  VAPID_PRIVATE_KEY: z.string().optional(),
  VAPID_SUBJECT: z.string().optional(),
})

/** Falso enquanto as variáveis do Supabase não foram definidas na hospedagem. */
export function isConfigured(): boolean {
  return Boolean(process.env.NEXT_PUBLIC_SUPABASE_URL && process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY && process.env.SUPABASE_SECRET_KEY)
}

let cached: z.infer<typeof schema> | undefined

/** Variáveis de ambiente validadas. Falha cedo, com mensagem clara, se algo faltar. */
export function env(): z.infer<typeof schema> {
  if (!cached) {
    const blank = (value: string | undefined) => (value === '' ? undefined : value)
    const parsed = schema.safeParse({
      NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
      SUPABASE_SECRET_KEY: process.env.SUPABASE_SECRET_KEY,
      NEXT_PUBLIC_VAPID_PUBLIC_KEY: blank(process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY),
      VAPID_PRIVATE_KEY: blank(process.env.VAPID_PRIVATE_KEY),
      VAPID_SUBJECT: blank(process.env.VAPID_SUBJECT),
    })
    if (!parsed.success) {
      const names = parsed.error.issues.map((issue) => issue.path.join('.')).join(', ')
      throw new Error(`Configuração inválida. Confira as variáveis de ambiente: ${names}`)
    }
    cached = parsed.data
  }
  return cached
}
