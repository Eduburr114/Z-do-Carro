import { NextResponse, type NextRequest } from 'next/server'
import { isConfigured } from '@/lib/env'
import { financeDeps } from '@/lib/finance/server'
import { MAX_WEBHOOK_BYTES, handleAsaasWebhook } from '@/lib/finance/webhook'
import { flushPushesAfterResponse } from '@/lib/push'
import { limiterKey } from '@/lib/security'

export const dynamic = 'force-dynamic'

/** Webhook de cobranças e transferências do Asaas. Autenticado pelo token do cabeçalho. */
export async function POST(request: NextRequest) {
  if (!isConfigured()) return NextResponse.json({ error: 'not_configured' }, { status: 503 })
  const length = Number(request.headers.get('content-length') ?? 0)
  if (length > MAX_WEBHOOK_BYTES) return NextResponse.json({ error: 'payload_too_large' }, { status: 413 })
  const ip = request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || request.headers.get('x-real-ip') || 'desconhecido'
  const reply = await handleAsaasWebhook(financeDeps(), {
    token: request.headers.get('asaas-access-token'),
    rawBody: await request.text(),
    clientKey: limiterKey('webhook', ip),
  })
  if (reply.status === 200) flushPushesAfterResponse()
  return NextResponse.json(reply.body, { status: reply.status, headers: { 'Cache-Control': 'no-store' } })
}
