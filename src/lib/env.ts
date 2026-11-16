import 'server-only'
import { z } from 'zod'

const optional = z.string().min(1).optional()

const schema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z.url(),
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: z.string().min(10),
  // Chave secreta: só no servidor (limite de tentativas, filas, webhooks e repasses).
  SUPABASE_SECRET_KEY: z.string().min(10),
  // Push (opcional): sem as chaves VAPID os avisos ficam só dentro do aplicativo.
  NEXT_PUBLIC_VAPID_PUBLIC_KEY: optional,
  VAPID_PRIVATE_KEY: optional,
  VAPID_SUBJECT: optional,
  // Endereço público (links nos e-mails e chamadas da rotina periódica).
  APP_URL: z.url().optional(),

  // Asaas. Sem a chave, a cobrança automática fica indisponível (o modo manual continua).
  ASAAS_API_KEY: optional,
  ASAAS_ENV: z.enum(['sandbox', 'production']).default('sandbox'),
  // Só para o emulador local (http://127.0.0.1...). Recusado em produção.
  ASAAS_BASE_URL: z.url().optional(),
  // Token que o Asaas envia no cabeçalho asaas-access-token dos webhooks (32+ caracteres).
  ASAAS_WEBHOOK_TOKEN: z.string().min(32).optional(),
  // Mecanismo de validação de saque (opcional, recomendado). Token próprio.
  ASAAS_TRANSFER_VALIDATION_TOKEN: z.string().min(32).optional(),

  // Rotina periódica (pagamentos vencidos, repasses, estornos, e-mails).
  CRON_SECRET: z.string().min(32).optional(),

  // Resend (e-mails transacionais). Sem a chave, os e-mails ficam registrados como "não enviados".
  RESEND_API_KEY: optional,
  RESEND_BASE_URL: z.url().optional(),
  EMAIL_FROM: optional,
  EMAIL_REPLY_TO: z.email().optional(),
})

export type Env = z.infer<typeof schema>

/** Falso enquanto as variáveis do Supabase não foram definidas na hospedagem. */
export function isConfigured(): boolean {
  return Boolean(process.env.NEXT_PUBLIC_SUPABASE_URL && process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY && process.env.SUPABASE_SECRET_KEY)
}

let cached: Env | undefined

const KEYS = Object.keys(schema.shape) as (keyof Env)[]

/** Variáveis de ambiente validadas. Falha cedo, com mensagem clara, se algo faltar. */
export function env(): Env {
  if (!cached) {
    const raw: Record<string, string | undefined> = {}
    for (const key of KEYS) raw[key] = process.env[key] === '' ? undefined : process.env[key]
    const parsed = schema.safeParse(raw)
    if (!parsed.success) {
      const names = parsed.error.issues.map((issue) => issue.path.join('.')).join(', ')
      throw new Error(`Configuração inválida. Confira as variáveis de ambiente: ${names}`)
    }
    const config = parsed.data
    if (config.ASAAS_BASE_URL && !/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//.test(config.ASAAS_BASE_URL)) {
      throw new Error('ASAAS_BASE_URL só pode apontar para o emulador local. Use ASAAS_ENV para sandbox ou produção.')
    }
    if (config.ASAAS_BASE_URL && config.ASAAS_ENV === 'production') {
      throw new Error('ASAAS_BASE_URL não pode ser usada com ASAAS_ENV=production.')
    }
    if (config.RESEND_BASE_URL && !/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//.test(config.RESEND_BASE_URL)) {
      throw new Error('RESEND_BASE_URL só pode apontar para o emulador local.')
    }
    cached = config
  }
  return cached
}
