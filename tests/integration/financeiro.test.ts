import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { createProvidersMock, LOCAL_ASAAS_API_KEY, LOCAL_RESEND_API_KEY } from '../../tools/local-stack/providers-mock'
import { CPF_TESTE, PNG_1PX, TestDb, service, type TestUser } from '../db/harness'
import { createAsaasClient, GatewayError } from '@/lib/payments/asaas'
import { createResendMailer } from '@/lib/email/resend'
import { sendPendingEmails } from '@/lib/email/outbox'
import { renderEmail, EMAIL_TEMPLATES } from '@/lib/email/templates'
import { createCharge, parseAsaasDate } from '@/lib/finance/charges'
import { handleAsaasWebhook, handleTransferValidation, tokenMatches } from '@/lib/finance/webhook'
import { runFinanceCycle } from '@/lib/finance/worker'
import type { ChargeToCreate, FinanceDeps } from '@/lib/finance/types'

/**
 * Integração do servidor do aplicativo com o banco e com os emuladores do Asaas
 * e do Resend (HTTP de verdade, sem rede externa, sem dinheiro real).
 */
const WEBHOOK_TOKEN = 'token-de-webhook-de-teste-com-32-caracteres-ou-mais'
const VALIDATION_TOKEN = 'token-de-validacao-de-saque-de-teste-com-32-caracteres'

let db: TestDb
let http: Server
let deps: FinanceDeps
let mock: ReturnType<typeof createProvidersMock>
let cliente: TestUser
let ze: TestUser
let hub: TestUser
let veiculo: string
let servico: string
const webhookReplies: number[] = []
const SLZ = { lat: -2.5307, lng: -44.3068 }

async function pedirEPagar(): Promise<{ id: string; externalId: string }> {
  await db.admin('delete from public.rate_limits')
  const id = await db.rpc<string>(cliente, 'create_request', { p_service_id: servico, p_vehicle_id: veiculo, p_address: 'Rua do Sol, 50', p_lat: SLZ.lat, p_lng: SLZ.lng })
  const start = await db.rpc<ChargeToCreate>(cliente, 'payment_start', { p_request_id: id })
  expect(await createCharge(deps, start)).toEqual({ ok: true })
  const [{ external_id }] = await db.admin<{ external_id: string }>('select external_id from public.payments where id = $1', [start.payment_id])
  return { id, externalId: external_id }
}
const status = async (id: string) => (await db.admin<{ status: string; financial_status: string }>('select status, financial_status from public.requests where id = $1', [id]))[0]

beforeAll(async () => {
  db = await TestDb.create()
  mock = createProvidersMock({
    quiet: true,
    // O "Asaas" entrega o webhook direto ao manipulador do aplicativo, com o token certo.
    webhook: async (body) => {
      const reply = await handleAsaasWebhook(deps, { token: WEBHOOK_TOKEN, rawBody: JSON.stringify(body), clientKey: 'teste' })
      webhookReplies.push(reply.status)
    },
    transferValidation: async (body) => (await handleTransferValidation(deps, { token: VALIDATION_TOKEN, rawBody: JSON.stringify(body) })).body as { status: string },
  })
  http = createServer((req, res) => {
    void mock.handle(req, res).then((handled) => {
      if (!handled) res.writeHead(404).end()
    })
  })
  await new Promise<void>((resolve) => http.listen(0, '127.0.0.1', resolve))
  const port = (http.address() as AddressInfo).port
  deps = {
    rpc: (name, args = {}) => db.rpc(service, name, args),
    gateway: createAsaasClient({ apiKey: LOCAL_ASAAS_API_KEY, environment: 'sandbox', baseUrl: `http://127.0.0.1:${port}/asaas/v3`, timeoutMs: 3000 }),
    webhookToken: WEBHOOK_TOKEN,
    transferValidationToken: VALIDATION_TOKEN,
    mailer: createResendMailer({ apiKey: LOCAL_RESEND_API_KEY, from: 'Zé do Carro <nao-responda@zedocarro.invalid>', baseUrl: `http://127.0.0.1:${port}/resend` }),
    appUrl: 'https://app.zedocarro.invalid',
  }

  hub = await db.createUser('hub_admin', 'Equipe HUB')
  cliente = await db.createUser('customer', 'Carla Cliente')
  ze = await db.createUser('provider', 'Zé Prestador')
  const servicos = await db.rpc<{ id: string; code: string }[]>(cliente, 'list_services')
  servico = servicos.find((s) => s.code === 'troca_pneu')!.id
  veiculo = await db.rpc<string>(cliente, 'save_vehicle', { p_plate: 'ABC1D23', p_brand: 'Fiat', p_model: 'Argo', p_year: 2021 })
  await db.rpc(cliente, 'save_payment_tax_id', { p_tax_id: CPF_TESTE })
  await db.rpc(ze, 'upload_document', { p_kind: 'identity', p_file_name: 'cnh.png', p_mime: 'image/png', p_content_base64: PNG_1PX })
  await db.rpc(ze, 'provider_apply', {
    p_doc_type: 'cpf', p_doc_number: '11144477735', p_legal_name: 'Zé Prestador', p_city: 'São Luís', p_experience: '',
    p_radius_km: 25, p_service_ids: [servico], p_lat: SLZ.lat, p_lng: SLZ.lng,
  })
  await db.rpc(hub, 'admin_decide_provider', { p_id: ze.sub, p_approved_service_ids: [servico] })
  const contrato = await db.rpc<{ id: string }>(ze, 'current_contract')
  await db.rpc(ze, 'accept_contract', { p_version_id: contrato.id, p_ip: '203.0.113.7', p_user_agent: 'teste' })
  await db.rpc(ze, 'set_online', { p_online: true, p_lat: SLZ.lat, p_lng: SLZ.lng })
})
afterAll(async () => {
  await mock?.settle()
  await new Promise((resolve) => http?.close(resolve))
  await db?.destroy()
})

describe('cliente do Asaas', () => {
  it('envia access_token e classifica erros', async () => {
    const semChave = createAsaasClient({ apiKey: 'errada', environment: 'sandbox', baseUrl: (deps.gateway as unknown as { base?: string }).base ?? `http://127.0.0.1:${(http.address() as AddressInfo).port}/asaas/v3` })
    await expect(semChave.getBalance()).rejects.toMatchObject({ status: 401, retryable: false, uncertain: false })
    mock.failNext('POST /transfers', 503)
    await expect(deps.gateway!.createPixTransfer({ valueCents: 100, pixKey: 'x@y.z', pixKeyType: 'EMAIL', description: 't', externalReference: 'r' }))
      .rejects.toMatchObject({ status: 503, retryable: true, uncertain: true })
    mock.failNext('POST /transfers', -1)
    const erro = await deps.gateway!.createPixTransfer({ valueCents: 100, pixKey: 'x@y.z', pixKeyType: 'EMAIL', description: 't', externalReference: 'r' }).catch((e) => e)
    expect(erro).toBeInstanceOf(GatewayError)
    expect(erro).toMatchObject({ status: null, uncertain: true })
  })
  it('converte data sem fuso do Asaas como horário de Brasília', () => {
    expect(parseAsaasDate('2026-11-17 14:20:50')).toBe('2026-11-17T17:20:50.000Z')
    expect(parseAsaasDate(null)).toBeNull()
  })
})

describe('cobrança, webhook e conciliação', () => {
  it('cria a cobrança Pix com QR Code e o webhook confirma pelo estado oficial', async () => {
    const { id, externalId } = await pedirEPagar()
    const [p] = await db.admin<{ status: string; pix_payload: string; pix_qr_image: string; pix_expires_at: Date }>(
      'select status, pix_payload, pix_qr_image, pix_expires_at from public.payments where external_id = $1', [externalId])
    expect(p.status).toBe('pending')
    expect(p.pix_payload).toContain(externalId)
    expect(p.pix_qr_image.length).toBeGreaterThan(20)
    expect(await status(id)).toMatchObject({ status: 'awaiting_payment' })
    mock.pay(externalId)
    await mock.settle()
    expect(await status(id)).toMatchObject({ status: 'searching', financial_status: 'payment_confirmed' })
    expect(webhookReplies.every((s) => s === 200)).toBe(true)
  })
  it('webhook sem o token certo é recusado e não grava nada', async () => {
    const corpo = JSON.stringify({ id: 'evt_forjado', event: 'PAYMENT_RECEIVED', payment: { id: 'pay_qualquer', status: 'RECEIVED', value: 9999 } })
    expect((await handleAsaasWebhook(deps, { token: null, rawBody: corpo, clientKey: 'atacante' })).status).toBe(401)
    expect((await handleAsaasWebhook(deps, { token: 'x'.repeat(48), rawBody: corpo, clientKey: 'atacante' })).status).toBe(401)
    expect(await db.admin(`select * from public.webhook_events where event_id = 'evt_forjado'`)).toEqual([])
    // Insistir esgota o limite de tentativas.
    let ultimo = 0
    for (let i = 0; i < 25; i++) ultimo = (await handleAsaasWebhook(deps, { token: 'errado', rawBody: corpo, clientKey: 'atacante' })).status
    expect(ultimo).toBe(429)
    expect(tokenMatches(WEBHOOK_TOKEN, WEBHOOK_TOKEN)).toBe(true)
  })
  it('webhook autêntico com dados falsos não confirma: vale o que a API diz', async () => {
    const { id, externalId } = await pedirEPagar()
    const forjado = { id: 'evt_conteudo_falso', event: 'PAYMENT_RECEIVED', payment: { id: externalId, status: 'RECEIVED', value: 80 } }
    expect((await handleAsaasWebhook(deps, { token: WEBHOOK_TOKEN, rawBody: JSON.stringify(forjado), clientKey: 'x' })).status).toBe(200)
    expect(await status(id)).toMatchObject({ status: 'awaiting_payment', financial_status: 'pending_payment' })
    expect((await handleAsaasWebhook(deps, { token: WEBHOOK_TOKEN, rawBody: '{"nao":"evento"}', clientKey: 'x' })).status).toBe(400)
    expect((await handleAsaasWebhook(deps, { token: WEBHOOK_TOKEN, rawBody: 'não é json', clientKey: 'x' })).status).toBe(400)
    await db.rpc(cliente, 'cancel_request', { p_id: id })
  })
  it('webhook repetido é reconhecido e não reprocessa', async () => {
    const [evento] = await db.admin<{ payload: Record<string, unknown> }>(`select payload from public.webhook_events where event_type = 'PAYMENT_RECEIVED' and status = 'processed' limit 1`)
    const antes = await db.admin('select count(*) from public.financial_ledger')
    const resposta = await handleAsaasWebhook(deps, { token: WEBHOOK_TOKEN, rawBody: JSON.stringify(evento.payload), clientKey: 'x' })
    expect(resposta).toMatchObject({ status: 200, body: { duplicate: true } })
    expect(await db.admin('select count(*) from public.financial_ledger')).toEqual(antes)
  })
  it('webhook perdido: a rotina periódica concilia pela API', async () => {
    const { id, externalId } = await pedirEPagar()
    const original = deps.webhookToken
    // Pagamento "sem webhook": o emulador não consegue entregar (token desligado).
    deps.webhookToken = null
    mock.pay(externalId)
    await mock.settle()
    deps.webhookToken = original
    expect(await status(id)).toMatchObject({ status: 'awaiting_payment' })
    await db.admin(`update public.payments set created_at = now() - interval '5 minutes', last_synced_at = null where external_id = $1`, [externalId])
    await runFinanceCycle(deps)
    expect(await status(id)).toMatchObject({ status: 'searching', financial_status: 'payment_confirmed' })
  })
  it('criação sem resposta: a conciliação acha a cobrança pela referência e não duplica', async () => {
    await db.admin('delete from public.rate_limits')
    const id = await db.rpc<string>(cliente, 'create_request', { p_service_id: servico, p_vehicle_id: veiculo, p_address: 'Rua do Sol, 50', p_lat: SLZ.lat, p_lng: SLZ.lng })
    const start = await db.rpc<ChargeToCreate>(cliente, 'payment_start', { p_request_id: id })
    // A cobrança é criada no provedor, mas a resposta não chega (simulado: só o provedor cria).
    const criada = await deps.gateway!.createPixPayment({ customer: [...mock.payments.values()][0].customer, valueCents: 8000, dueDate: '2026-12-01', description: 'x', externalReference: start.attempt_key })
    await db.admin(`update public.payments set created_at = now() - interval '5 minutes' where id = $1`, [start.payment_id])
    await runFinanceCycle(deps)
    const [p] = await db.admin<{ status: string; external_id: string }>('select status, external_id from public.payments where id = $1', [start.payment_id])
    expect(p).toMatchObject({ status: 'pending', external_id: criada.id })
    expect([...mock.payments.values()].filter((x) => x.externalReference === start.attempt_key)).toHaveLength(1)
    await db.rpc(cliente, 'cancel_request', { p_id: id })
    await runFinanceCycle(deps)
    expect(mock.payments.get(criada.id)?.deleted).toBe(true)
  })
})

describe('estorno e repasse ponta a ponta', () => {
  it('cancelamento depois do pagamento: a rotina estorna no provedor', async () => {
    const { id, externalId } = await pedirEPagar()
    mock.pay(externalId)
    await mock.settle()
    await db.rpc(cliente, 'cancel_request', { p_id: id })
    await runFinanceCycle(deps)
    await mock.settle()
    expect(mock.payments.get(externalId)?.status).toBe('REFUNDED')
    expect(await status(id)).toMatchObject({ financial_status: 'refunded' })
  })
  it('repasse: transferência validada, concluída e conciliada uma única vez', async () => {
    const { id, externalId } = await pedirEPagar()
    mock.pay(externalId)
    await mock.settle()
    await db.rpc(ze, 'accept_request', { p_id: id })
    for (const to of ['en_route', 'in_progress', 'completed']) await db.rpc(ze, 'advance_request', { p_id: id, p_to: to })
    await db.rpc(cliente, 'confirm_completion', { p_id: id })
    await db.rpc(ze, 'save_payment_account', { p_pix_key_type: 'EMAIL', p_pix_key: 'ze@exemplo.invalid', p_holder_name: 'Zé Prestador' })
    const [conta] = await db.rpc<{ id: string }[]>(hub, 'finance_accounts')
    await db.rpc(hub, 'finance_review_account', { p_account_id: conta.id, p_approve: true })
    await db.admin(`update public.payouts set scheduled_for = now() - interval '1 minute' where request_id = $1`, [id])
    await db.admin(`update public.provider_payment_accounts set usable_from = now() - interval '1 minute'`)
    // Duas rodadas ao mesmo tempo: uma só transferência.
    await Promise.all([runFinanceCycle(deps), runFinanceCycle(deps)])
    await mock.settle()
    const transferencias = [...mock.transfers.values()].filter((t) => t.status === 'DONE')
    expect(transferencias).toHaveLength(1)
    expect(transferencias[0]).toMatchObject({ value: 64, pixAddressKey: 'ze@exemplo.invalid', pixAddressKeyType: 'EMAIL' })
    expect(await status(id)).toMatchObject({ financial_status: 'payout_completed' })
    // Outra transferência para o mesmo repasse é recusada pela validação de saque.
    const [{ id: payoutId }] = await db.admin<{ id: string }>('select id from public.payouts where request_id = $1', [id])
    const segunda = await deps.gateway!.createPixTransfer({ valueCents: 6400, pixKey: 'ze@exemplo.invalid', pixKeyType: 'EMAIL', description: 'x', externalReference: payoutId })
    await mock.settle()
    expect(mock.transfers.get(segunda.id)?.status).toBe('CANCELLED')
    // Transferência que não é repasse nem saque autorizado também.
    const intrusa = await deps.gateway!.createPixTransfer({ valueCents: 50000, pixKey: 'golpe@exemplo.invalid', pixKeyType: 'EMAIL', description: 'x', externalReference: 'qualquer' })
    await mock.settle()
    expect(mock.transfers.get(intrusa.id)?.status).toBe('CANCELLED')
    // Saque autorizado pela equipe financeira passa.
    await db.rpc(hub, 'finance_authorize_withdrawal', { p_amount: 10, p_note: 'Retirada de receita para a conta da HUB' })
    const saque = await deps.gateway!.createPixTransfer({ valueCents: 1000, pixKey: 'hub@exemplo.invalid', pixKeyType: 'EMAIL', description: 'x', externalReference: 'saque' })
    await mock.settle()
    expect(mock.transfers.get(saque.id)?.status).toBe('DONE')
  })
  it('falha na transferência volta para nova tentativa', async () => {
    const { id, externalId } = await pedirEPagar()
    mock.pay(externalId)
    await mock.settle()
    await db.rpc(ze, 'accept_request', { p_id: id })
    for (const to of ['en_route', 'in_progress', 'completed']) await db.rpc(ze, 'advance_request', { p_id: id, p_to: to })
    await db.rpc(cliente, 'confirm_completion', { p_id: id })
    await db.admin(`update public.provider_payment_accounts set pix_key = 'falha@exemplo.invalid' where status = 'active'`)
    await db.admin(`update public.payouts set scheduled_for = now() - interval '1 minute' where request_id = $1`, [id])
    await runFinanceCycle(deps)
    await mock.settle()
    const [po] = await db.admin<{ status: string; final_failure: boolean; next_attempt_at: Date }>('select status, final_failure, next_attempt_at from public.payouts where request_id = $1', [id])
    expect(po).toMatchObject({ status: 'failed', final_failure: false })
    expect(new Date(po.next_attempt_at).getTime()).toBeGreaterThan(Date.now())
    expect(await status(id)).toMatchObject({ financial_status: 'payout_failed' })
  })
})

describe('e-mails pelo Resend', () => {
  it('todos os modelos têm assunto, HTML e texto, sem dados sensíveis crus', () => {
    for (const t of EMAIL_TEMPLATES) {
      const email = renderEmail(t, { number: 1001, service: 'Troca de pneu', total: 'R$ 80,00', provider_net: 'R$ 64,00', url_customer: '/cliente/pedidos/x', title: '<b>x</b>', body: 'y', url: '/hub' }, 'https://app.invalid')!
      expect(email.subject.length).toBeGreaterThan(5)
      expect(email.html).toContain('<!doctype html>')
      expect(email.text.length).toBeGreaterThan(20)
      expect(email.html).not.toContain('<b>x</b>')
    }
    expect(renderEmail('nao_existe', {}, 'https://app.invalid')).toBeNull()
  })
  it('envia a fila uma vez (idempotência) e trata falhas temporárias e definitivas', async () => {
    await db.admin(`update public.notification_logs set status = 'sent' where status = 'queued'`)
    await db.admin(`insert into public.notification_logs (template, user_id, to_email, data, idempotency_key) values
      ('pagamento_confirmado', $1, 'cliente@exemplo.invalid', '{"number": 1, "service": "Troca", "total": "R$ 1,00"}', 'teste:ok'),
      ('pagamento_confirmado', $1, 'cliente+falha-temporaria@exemplo.invalid', '{}', 'teste:temp'),
      ('pagamento_confirmado', $1, 'cliente+falha@exemplo.invalid', '{}', 'teste:def')`, [cliente.sub])
    expect(await sendPendingEmails(deps)).toMatchObject({ sent: 1, retry: 1, failed: 1 })
    const linhas = await db.admin<{ idempotency_key: string; status: string; provider_message_id: string | null }>(
      `select idempotency_key, status, provider_message_id from public.notification_logs where idempotency_key like 'teste:%' order by idempotency_key`)
    expect(linhas).toEqual([
      expect.objectContaining({ idempotency_key: 'teste:def', status: 'failed' }),
      expect.objectContaining({ idempotency_key: 'teste:ok', status: 'sent' }),
      expect.objectContaining({ idempotency_key: 'teste:temp', status: 'queued' }),
    ])
    // Reenvio com a mesma chave (ex.: resposta perdida) não gera e-mail novo.
    const enviados = mock.emails.length
    await deps.mailer!.send({ to: 'cliente@exemplo.invalid', subject: 's', html: 'h', text: 't', idempotencyKey: 'teste:ok', tags: [] })
    expect(mock.emails.length).toBe(enviados)
    expect(mock.emails.at(-1)?.html).toContain('Recebemos o seu Pix')
  })
  it('sem provedor configurado, nada é marcado como enviado', async () => {
    await db.admin(`insert into public.notification_logs (template, user_id, to_email, idempotency_key) values ('repasse_realizado', $1, 'ze@exemplo.invalid', 'teste:sem-provedor')`, [ze.sub])
    await sendPendingEmails({ ...deps, mailer: null })
    expect(await db.admin(`select status from public.notification_logs where idempotency_key = 'teste:sem-provedor'`)).toEqual([{ status: 'skipped' }])
  })
})
