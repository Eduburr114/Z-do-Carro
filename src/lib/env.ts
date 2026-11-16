import 'server-only'
import { z } from 'zod'

const schema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z.url(),
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: z.string().min(10),
})

let cached: z.infer<typeof schema> | undefined

/** Variáveis de ambiente validadas. Falha cedo, com mensagem clara, se algo faltar. */
export function env(): z.infer<typeof schema> {
  if (!cached) {
    const parsed = schema.safeParse({
      NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    })
    if (!parsed.success) {
      const names = parsed.error.issues.map((issue) => issue.path.join('.')).join(', ')
      throw new Error(`Configuração inválida. Confira as variáveis de ambiente: ${names}`)
    }
    cached = parsed.data
  }
  return cached
}
