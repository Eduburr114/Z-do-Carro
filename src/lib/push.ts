import 'server-only'
import { after } from 'next/server'
import { sendNotification, setVapidDetails } from 'web-push'
import { env } from '@/lib/env'
import { createAdminClient } from '@/lib/supabase/admin'

type QueueItem = { id: number; title: string; body: string; url: string; subscriptions: { endpoint: string; p256dh: string; auth: string }[] }

/**
 * Envia como push os avisos que o banco acabou de gerar. A fila entrega cada
 * aviso uma única vez; inscrições que o navegador invalidou são removidas.
 */
export async function sendPendingPushes(): Promise<{ sent: number; failed: number; skipped?: string }> {
  const config = env()
  if (!config.NEXT_PUBLIC_VAPID_PUBLIC_KEY || !config.VAPID_PRIVATE_KEY || !config.VAPID_SUBJECT) return { sent: 0, failed: 0, skipped: 'vapid_not_configured' }
  setVapidDetails(config.VAPID_SUBJECT, config.NEXT_PUBLIC_VAPID_PUBLIC_KEY, config.VAPID_PRIVATE_KEY)
  const admin = createAdminClient()
  const { data, error } = await admin.rpc('push_take')
  if (error) throw new Error(`push_take: ${error.code}`)
  let sent = 0
  let failed = 0
  await Promise.all(
    ((data ?? []) as QueueItem[]).flatMap((item) =>
      item.subscriptions.map(async (sub) => {
        try {
          await sendNotification(
            { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
            JSON.stringify({ title: item.title, body: item.body, url: item.url, tag: `aviso-${item.id}` }),
            { TTL: 60 * 60, urgency: 'high' },
          )
          sent++
        } catch (err) {
          failed++
          const status = (err as { statusCode?: number }).statusCode
          if (status === 404 || status === 410) await admin.rpc('push_gone', { p_endpoint: sub.endpoint })
        }
      }),
    ),
  )
  return { sent, failed }
}

/** Agenda o envio para depois da resposta, sem atrasar quem fez a ação. */
export function flushPushesAfterResponse(): void {
  after(async () => {
    try {
      await sendPendingPushes()
    } catch (error) {
      console.error('[push] falha no envio', error instanceof Error ? error.message : error)
    }
  })
}
