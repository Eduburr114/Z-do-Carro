import { NextResponse, type NextRequest } from 'next/server'
import { env, isConfigured } from '@/lib/env'
import { financeDeps } from '@/lib/finance/server'
import { tokenMatches } from '@/lib/finance/webhook'
import { runFinanceCycle } from '@/lib/finance/worker'
import { sendPendingPushes } from '@/lib/push'

export const dynamic = 'force-dynamic'
export const maxDuration = 60

/**
 * Rotina financeira: prazos, conciliação, estornos, repasses e e-mails.
 * Chamada a cada poucos minutos por um agendador (ver docs/FINANCEIRO.md),
 * com Authorization: Bearer CRON_SECRET. Pode rodar em paralelo sem duplicar nada.
 */
async function run(request: NextRequest) {
  if (!isConfigured()) return NextResponse.json({ error: 'not_configured' }, { status: 503 })
  const secret = env().CRON_SECRET
  const auth = request.headers.get('authorization')
  if (!secret || !tokenMatches(auth?.startsWith('Bearer ') ? auth.slice(7) : null, secret)) {
    return NextResponse.json({ error: 'unauthorized' }, { status: 401 })
  }
  const summary = await runFinanceCycle(financeDeps())
  const push = await sendPendingPushes().catch((error) => ({ error: error instanceof Error ? error.message : 'erro' }))
  return NextResponse.json({ ok: true, summary, push }, { headers: { 'Cache-Control': 'no-store' } })
}

export const GET = run
export const POST = run
