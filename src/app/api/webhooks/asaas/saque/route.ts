import { NextResponse, type NextRequest } from 'next/server'
import { isConfigured } from '@/lib/env'
import { financeDeps } from '@/lib/finance/server'
import { MAX_WEBHOOK_BYTES, handleTransferValidation } from '@/lib/finance/webhook'

export const dynamic = 'force-dynamic'

/**
 * Mecanismo de validação de saque do Asaas: responde APPROVED só para repasse
 * conhecido (valor e chave conferidos) ou saque autorizado pela equipe.
 */
export async function POST(request: NextRequest) {
  if (!isConfigured()) return NextResponse.json({ error: 'not_configured' }, { status: 503 })
  if (Number(request.headers.get('content-length') ?? 0) > MAX_WEBHOOK_BYTES) {
    return NextResponse.json({ status: 'REFUSED', refuseReason: 'Requisição grande demais' })
  }
  const reply = await handleTransferValidation(financeDeps(), {
    token: request.headers.get('asaas-access-token'),
    rawBody: await request.text(),
  })
  return NextResponse.json(reply.body, { status: reply.status, headers: { 'Cache-Control': 'no-store' } })
}
