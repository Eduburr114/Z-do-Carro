import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { CPF_TESTE, PNG_1PX, TestDb, pagarPix, service, type TestUser } from './harness'

/**
 * Infraestrutura financeira: máquina de estados, razão contábil, idempotência,
 * repasses, estornos, disputas, preços, comissões, permissões e e-mails.
 * Nada aqui fala com provedor real: o papel do servidor (service_role) faz o
 * que o webhook e o processador de repasses fariam com dados do provedor.
 */
let db: TestDb
let hub: TestUser
let financeiro: TestUser
let operador: TestUser
let cliente: TestUser
let ze: TestUser
let veiculo: string
let servicos: { id: string; code: string; base_price: number; category_code: string }[]

const SLZ = { lat: -2.5307, lng: -44.3068 }
const denied = { code: '42501' }
const ZE_CPF = '11144477735'

type Pedido = {
  id: string; status: string; financial_status: string; total: number; price: number; discount_amount: number; fee_amount: number
  commission_percent: number; commission_amount: number; provider_net: number; promotion_name: string | null
  payout: { status: string; scheduled_for: string; amount: number } | null
  payments: { id: string; status: string; amount: number }[]
}
type Claim = { payout_id: string; claim_token: string; amount_cents: number; pix_key: string; pix_key_type: string }

const svc = (code: string) => servicos.find((s) => s.code === code)!.id
const detalhe = (id: string) => db.rpc<Pedido>(cliente, 'request_detail', { p_id: id })
const balancete = async () => Number((await db.admin<{ s: string }>(
  `select coalesce(sum(case when direction = 'D' then amount_cents else -amount_cents end), 0) as s from public.financial_ledger`))[0].s)
const saldo = async (conta: string) => Number((await db.admin<{ s: string }>(
  `select coalesce(sum(case when direction = 'D' then amount_cents else -amount_cents end), 0) as s from public.financial_ledger where account = $1`, [conta]))[0].s)

async function pedir(code = 'troca_pneu', pagar = true) {
  // Os testes criam muitos pedidos; o limite por hora do cliente é zerado aqui.
  await db.admin('delete from public.rate_limits')
  const id = await db.rpc<string>(cliente, 'create_request', {
    p_service_id: svc(code), p_vehicle_id: veiculo, p_address: 'Rua Grande, 200 — Centro', p_lat: SLZ.lat, p_lng: SLZ.lng,
  })
  if (pagar) await pagarPix(db, cliente, id)
  return id
}
/** Leva um pedido pago até a conclusão (sem confirmar). */
async function executar(id: string, prestador = ze) {
  await db.rpc(prestador, 'accept_request', { p_id: id })
  for (const to of ['en_route', 'in_progress', 'completed']) await db.rpc(prestador, 'advance_request', { p_id: id, p_to: to })
}
async function concluido(code = 'troca_pneu') {
  const id = await pedir(code)
  await executar(id)
  await db.rpc(cliente, 'confirm_completion', { p_id: id })
  return id
}
/** Faz o repasse vencer agora e a conta ficar utilizável. */
async function vencer(id: string) {
  await db.admin(`update public.payouts set scheduled_for = now() - interval '1 minute' where request_id = $1`, [id])
  await db.admin(`update public.provider_payment_accounts set usable_from = now() - interval '1 minute' where status = 'active'`)
}

beforeAll(async () => {
  db = await TestDb.create()
  hub = await db.createUser('hub_admin', 'Equipe HUB')
  cliente = await db.createUser('customer', 'Carla Cliente')
  ze = await db.createUser('provider', 'Zé Prestador')
  servicos = await db.rpc(cliente, 'list_services')
  veiculo = await db.rpc<string>(cliente, 'save_vehicle', { p_plate: 'ABC1D23', p_brand: 'Fiat', p_model: 'Argo', p_year: 2021 })
  await db.rpc(ze, 'upload_document', { p_kind: 'identity', p_file_name: 'cnh.png', p_mime: 'image/png', p_content_base64: PNG_1PX })
  await db.rpc(ze, 'provider_apply', {
    p_doc_type: 'cpf', p_doc_number: ZE_CPF, p_legal_name: 'Zé Prestador', p_city: 'São Luís', p_experience: '',
    p_radius_km: 25, p_service_ids: servicos.map((s) => s.id), p_lat: SLZ.lat, p_lng: SLZ.lng,
  })
  await db.rpc(hub, 'admin_decide_provider', { p_id: ze.sub, p_approved_service_ids: servicos.map((s) => s.id) })
  const contrato = await db.rpc<{ id: string }>(ze, 'current_contract')
  await db.rpc(ze, 'accept_contract', { p_version_id: contrato.id, p_ip: '203.0.113.7', p_user_agent: 'teste' })
  await db.rpc(ze, 'set_online', { p_online: true, p_lat: SLZ.lat, p_lng: SLZ.lng })

  // Equipe com papéis separados: um só financeiro, outro só operação.
  financeiro = await db.createUser('hub_admin', 'Gestora Financeira')
  operador = await db.createUser('hub_admin', 'Operador')
  await db.rpc(hub, 'admin_set_staff_role', { p_user_id: financeiro.sub, p_role: 'admin', p_grant: false })
  await db.rpc(hub, 'admin_set_staff_role', { p_user_id: operador.sub, p_role: 'finance', p_grant: false })
})
afterAll(async () => {
  await db.destroy()
})

describe('permissões e segregação', () => {
  it('cliente, prestador e operador não acessam dados nem ações financeiras', async () => {
    for (const quem of [cliente, ze, operador]) {
      await expect(db.rpc(quem, 'finance_dashboard')).rejects.toMatchObject(denied)
      await expect(db.rpc(quem, 'finance_payouts')).rejects.toMatchObject(denied)
      await expect(db.rpc(quem, 'finance_request_refund', { p_request_id: '00000000-0000-0000-0000-000000000000', p_note: 'tentativa indevida' })).rejects.toMatchObject(denied)
    }
    expect(await db.rpc(financeiro, 'finance_dashboard')).toHaveProperty('balances')
  })
  it('o gestor financeiro não altera preço, comissão nem credenciamento', async () => {
    await expect(db.rpc(financeiro, 'admin_overview')).rejects.toMatchObject(denied)
    await expect(db.rpc(financeiro, 'admin_create_commission_rule', { p_name: 'x', p_scope: 'category', p_category_code: 'pneus', p_provider_id: null, p_percent: 1, p_starts_at: null, p_ends_at: null }))
      .rejects.toMatchObject(denied)
    await expect(db.rpc(financeiro, 'admin_set_region_price', { p_service_id: svc('troca_pneu'), p_region_id: '00000000-0000-0000-0000-000000000000', p_price: 1 })).rejects.toMatchObject(denied)
    expect(await db.rpc<{ staff: string[] }>(financeiro, 'my_access')).toMatchObject({ staff: ['finance'] })
  })
  it('funções do servidor recusam qualquer usuário autenticado', async () => {
    const chamadas = [
      `select public.payment_sync('pay_x', null, 'RECEIVED', 100, 100, false)`,
      `select public.payout_claim(10)`,
      `select public.payout_validate_transfer('tr', 100, null, null)`,
      `select public.webhook_record('asaas', 'evt', 'PAYMENT_RECEIVED', null, '{}'::jsonb)`,
      `select public.email_claim(10)`,
      `select public.finance_tick()`,
      `select public.refund_claim(10)`,
    ]
    for (const sql of chamadas) await expect(db.query(hub, sql)).rejects.toMatchObject(denied)
  })
  it('nenhuma tabela financeira é lida direto', async () => {
    for (const t of ['payments', 'payouts', 'financial_ledger', 'payment_customers', 'provider_payment_accounts', 'webhook_events', 'audit_logs', 'notification_logs']) {
      await expect(db.query(financeiro, `select * from public.${t}`)).rejects.toMatchObject(denied)
    }
  })
  it('só o administrador muda papéis da equipe', async () => {
    await expect(db.rpc(financeiro, 'admin_set_staff_role', { p_user_id: financeiro.sub, p_role: 'admin', p_grant: true })).rejects.toMatchObject(denied)
    await expect(db.rpc(cliente, 'admin_set_staff_role', { p_user_id: cliente.sub, p_role: 'finance', p_grant: true })).rejects.toMatchObject(denied)
  })
})

describe('pagamento Pix', () => {
  it('CPF é obrigatório e validado antes da cobrança', async () => {
    const id = await pedir('troca_pneu', false)
    await expect(db.rpc(cliente, 'payment_start', { p_request_id: id })).rejects.toMatchObject({ message: 'tax_id_required' })
    await expect(db.rpc(cliente, 'save_payment_tax_id', { p_tax_id: '123.456.789-00' })).rejects.toMatchObject({ message: 'invalid_tax_id' })
    await db.rpc(cliente, 'save_payment_tax_id', { p_tax_id: CPF_TESTE })
    expect(await db.rpc(cliente, 'payment_profile')).toMatchObject({ has_tax_id: true, tax_id_masked: '***.982.***-25' })
    await db.rpc(cliente, 'cancel_request', { p_id: id })
  })
  it('a cobrança é idempotente: pedir de novo devolve a mesma', async () => {
    const id = await pedir('troca_pneu', false)
    const a = await db.rpc<{ action: string; payment_id: string }>(cliente, 'payment_start', { p_request_id: id })
    expect(a.action).toBe('create')
    expect(await db.rpc(cliente, 'payment_start', { p_request_id: id })).toMatchObject({ action: 'wait', payment_id: a.payment_id })
    await db.rpc(service, 'payment_charge_created', { p_payment_id: a.payment_id, p_external_id: 'pay_idem', p_status: 'PENDING', p_pix_payload: 'x', p_pix_qr_image: 'y', p_pix_expires_at: null })
    expect(await db.rpc(cliente, 'payment_start', { p_request_id: id })).toMatchObject({ action: 'existing', payment_id: a.payment_id })
    const pedido = await detalhe(id)
    expect(pedido.payments).toHaveLength(1)
    await db.rpc(cliente, 'cancel_request', { p_id: id })
    // Cobrança aberta de pedido cancelado fica marcada para remoção no provedor.
    const [p] = await db.admin<{ status: string; remote_cancel_pending: boolean }>('select status, remote_cancel_pending from public.payments where id = $1', [a.payment_id])
    expect(p).toMatchObject({ status: 'cancelled', remote_cancel_pending: true })
    const lista = await db.rpc<{ payment_id: string; remote_cancel: boolean }[]>(service, 'payments_to_reconcile')
    expect(lista.find((x) => x.payment_id === a.payment_id)).toMatchObject({ remote_cancel: true })
    await db.rpc(service, 'payment_remote_cancelled', { p_payment_id: a.payment_id })
  })
  it('pagamento confirmado libera o pedido e lança o razão', async () => {
    const id = await pedir()
    const pedido = await detalhe(id)
    expect(pedido).toMatchObject({ status: 'searching', financial_status: 'payment_confirmed' })
    expect(pedido.payments[0]).toMatchObject({ status: 'confirmed', amount: 80 })
    expect(await balancete()).toBe(0)
    const linhas = await db.admin<{ account: string; direction: string; amount_cents: string }>(
      'select account, direction, amount_cents from public.financial_ledger where request_id = $1 order by id', [id])
    expect(linhas.map((l) => [l.account, l.direction, Number(l.amount_cents)])).toEqual([
      ['cash_gateway', 'D', 7901], ['gateway_fees', 'D', 99], ['customer_funds_held', 'C', 8000],
    ])
    await db.rpc(cliente, 'cancel_request', { p_id: id })
  })
  it('pagamento não confirmado: PENDING não libera e o prazo encerra o pedido', async () => {
    const id = await pedir('troca_pneu', false)
    await db.rpc(cliente, 'save_payment_tax_id', { p_tax_id: CPF_TESTE })
    const s = await db.rpc<{ payment_id: string }>(cliente, 'payment_start', { p_request_id: id })
    await db.rpc(service, 'payment_charge_created', { p_payment_id: s.payment_id, p_external_id: 'pay_pendente', p_status: 'PENDING', p_pix_payload: 'x', p_pix_qr_image: 'y', p_pix_expires_at: null })
    await db.rpc(service, 'payment_sync', { p_external_id: 'pay_pendente', p_external_reference: null, p_status: 'PENDING', p_value_cents: 8000, p_net_cents: 8000 })
    expect(await detalhe(id)).toMatchObject({ status: 'awaiting_payment', financial_status: 'pending_payment' })
    await db.admin(`update public.requests set payment_due_at = now() - interval '1 minute' where id = $1`, [id])
    expect(await db.rpc(service, 'finance_tick')).toMatchObject({ expired: 1 })
    expect(await detalhe(id)).toMatchObject({ status: 'cancelled', financial_status: 'cancelled' })
    // Pagou depois do prazo: pagamento órfão, estornado automaticamente.
    expect((await db.rpc<{ result: string }>(service, 'payment_sync', { p_external_id: 'pay_pendente', p_external_reference: null, p_status: 'RECEIVED', p_value_cents: 8000, p_net_cents: 7901 })).result)
      .toBe('late_payment')
    const [refund] = await db.admin<{ reason: string; status: string }>(
      'select f.reason, f.status from public.refunds f join public.payments p on p.id = f.payment_id where p.external_id = $1', ['pay_pendente'])
    expect(refund).toMatchObject({ reason: 'late_payment', status: 'requested' })
    expect(await balancete()).toBe(0)
  })
  it('eventos repetidos ou fora de ordem não regridem nem duplicam', async () => {
    const id = await pedir('troca_pneu', false)
    const { externalId } = await pagarPix(db, cliente, id)
    const antes = await db.admin('select count(*) from public.financial_ledger where request_id = $1', [id])
    await db.rpc(service, 'payment_sync', { p_external_id: externalId, p_external_reference: null, p_status: 'RECEIVED', p_value_cents: 8000, p_net_cents: 7901 })
    await db.rpc(service, 'payment_sync', { p_external_id: externalId, p_external_reference: null, p_status: 'PENDING', p_value_cents: 8000, p_net_cents: 8000 })
    await db.rpc(service, 'payment_sync', { p_external_id: externalId, p_external_reference: null, p_status: 'OVERDUE', p_value_cents: 8000, p_net_cents: 8000 })
    expect(await db.admin('select count(*) from public.financial_ledger where request_id = $1', [id])).toEqual(antes)
    expect((await detalhe(id)).payments[0].status).toBe('confirmed')
    await db.rpc(cliente, 'cancel_request', { p_id: id })
  })
  it('webhook com o mesmo id é registrado uma vez só', async () => {
    const args = { p_provider: 'asaas', p_event_id: 'evt_teste_1', p_event_type: 'PAYMENT_RECEIVED', p_resource_id: 'pay_x', p_payload: { id: 'evt_teste_1' } }
    const a = await db.rpc<{ id: number; duplicate: boolean }>(service, 'webhook_record', args)
    expect(a.duplicate).toBe(false)
    expect((await db.rpc<{ duplicate: boolean }>(service, 'webhook_record', args)).duplicate).toBe(false) // ainda não processado: pode reprocessar
    await db.rpc(service, 'webhook_done', { p_id: a.id, p_status: 'processed' })
    expect(await db.rpc(service, 'webhook_record', args)).toMatchObject({ id: a.id, duplicate: true })
    expect(await db.admin(`select count(*)::int as n from public.webhook_events where event_id = 'evt_teste_1'`)).toEqual([{ n: 1 }])
  })
  it('cobrança desconhecida é ignorada (webhook forjado não cria nada)', async () => {
    expect(await db.rpc(service, 'payment_sync', { p_external_id: 'pay_inexistente', p_external_reference: 'nao-e-uuid', p_status: 'RECEIVED', p_value_cents: 100000, p_net_cents: 100000 }))
      .toMatchObject({ result: 'unknown' })
  })
  it('pagamento em duplicidade e valor divergente viram estorno automático', async () => {
    const id = await pedir()
    // Segunda cobrança paga para o mesmo pedido (ex.: criada antes da primeira ser vinculada).
    const [{ id: dup }] = await db.admin<{ id: string }>(
      `insert into public.payments (request_id, kind, method, status, amount_cents, external_id) values ($1, 'service', 'pix_asaas', 'pending', 8000, 'pay_dup') returning id`, [id])
    expect((await db.rpc<{ result: string }>(service, 'payment_sync', { p_external_id: 'pay_dup', p_external_reference: null, p_status: 'RECEIVED', p_value_cents: 8000, p_net_cents: 7901 })).result).toBe('duplicate')
    const [p] = await db.admin<{ status: string; orphan_reason: string }>('select status, orphan_reason from public.payments where id = $1', [dup])
    expect(p).toMatchObject({ status: 'refund_pending', orphan_reason: 'duplicate' })

    const outro = await pedir('troca_pneu', false)
    expect((await pagarPix(db, cliente, outro, null, { value: 100 })).result).toBe('amount_mismatch')
    expect(await detalhe(outro)).toMatchObject({ status: 'awaiting_payment' })
    await db.rpc(cliente, 'cancel_request', { p_id: id })
    await db.rpc(cliente, 'cancel_request', { p_id: outro })
    expect(await balancete()).toBe(0)
  })
})

describe('estorno', () => {
  it('cancelamento depois do pagamento e antes do serviço estorna tudo', async () => {
    const id = await pedir()
    await db.rpc(ze, 'accept_request', { p_id: id })
    await db.rpc(cliente, 'cancel_request', { p_id: id })
    expect(await detalhe(id)).toMatchObject({ status: 'cancelled', financial_status: 'refund_pending' })
    const fila = await db.rpc<{ refund_id: string; external_id: string; reason: string }[]>(service, 'refund_claim')
    const [{ external_id: externo }] = await db.admin<{ external_id: string }>('select external_id from public.payments where request_id = $1', [id])
    const meu = fila.find((f) => f.external_id === externo)!
    expect(meu.reason).toBe('cancelled_before_service')
    expect(meu).toBeDefined()
    await db.rpc(service, 'refund_result', { p_refund_id: meu.refund_id, p_ok: true })
    await db.rpc(service, 'payment_sync', { p_external_id: meu.external_id, p_external_reference: null, p_status: 'REFUNDED', p_value_cents: 8000, p_net_cents: 7901 })
    expect(await detalhe(id)).toMatchObject({ financial_status: 'refunded' })
    // Repetir o REFUNDED não lança de novo.
    const n = await db.admin('select count(*) from public.financial_ledger where request_id = $1', [id])
    await db.rpc(service, 'payment_sync', { p_external_id: meu.external_id, p_external_reference: null, p_status: 'REFUNDED', p_value_cents: 8000, p_net_cents: 7901 })
    expect(await db.admin('select count(*) from public.financial_ledger where request_id = $1', [id])).toEqual(n)
    expect(await balancete()).toBe(0)
    // Os outros estornos da fila (testes anteriores) seguem.
    for (const f of fila.filter((x) => x !== meu)) await db.rpc(service, 'refund_result', { p_refund_id: f.refund_id, p_ok: true })
  })
  it('falha de estorno tem novas tentativas e depois alerta a equipe', async () => {
    const id = await pedir()
    await db.rpc(cliente, 'cancel_request', { p_id: id })
    const [{ id: refundId }] = await db.admin<{ id: string }>(
      `select f.id from public.refunds f join public.payments p on p.id = f.payment_id where p.request_id = $1`, [id])
    for (let i = 0; i < 5; i++) {
      await db.admin(`update public.refunds set next_attempt_at = now() where id = $1`, [refundId])
      const fila = await db.rpc<{ refund_id: string }[]>(service, 'refund_claim')
      expect(fila.map((f) => f.refund_id)).toContain(refundId)
      await db.rpc(service, 'refund_result', { p_refund_id: refundId, p_ok: false, p_error: 'Saldo insuficiente', p_retryable: true })
    }
    const [f] = await db.admin<{ status: string }>('select status from public.refunds where id = $1', [refundId])
    expect(f.status).toBe('failed')
    const alertas = (await db.rpc<{ title: string }[]>(financeiro, 'my_notifications')).map((n) => n.title)
    expect(alertas).toContain('Estorno não concluído')
    await db.rpc(financeiro, 'finance_retry_refund', { p_refund_id: refundId })
    await expect(db.rpc(financeiro, 'finance_retry_refund', { p_refund_id: refundId })).rejects.toMatchObject({ code: '23505' })
  })
})

describe('preços e comissões', () => {
  it('o cliente vê o total antes de confirmar, com preço da região, desconto e taxa', async () => {
    const [{ id: regiao }] = await db.admin<{ id: string }>(`select id from public.regions where code = 'sao_luis'`)
    await db.rpc(hub, 'admin_set_region_price', { p_service_id: svc('troca_oleo'), p_region_id: regiao, p_price: 130 })
    const agora = new Date()
    await db.rpc(hub, 'admin_save_promotion', {
      p_id: null, p_name: 'Inauguração São Luís', p_kind: 'percent', p_value: 10, p_service_id: null, p_category_code: 'manutencao', p_region_id: regiao,
      p_starts_at: new Date(agora.getTime() - 60_000).toISOString(), p_ends_at: new Date(agora.getTime() + 86400_000).toISOString(), p_max_redemptions: 100, p_active: true,
    })
    const regras = { p_commission_percent: 20, p_payout_days: 7, p_confirm_hours: 24, p_payment_window_minutes: 30, p_min_charge_amount: 5, p_payment_provider: 'asaas', p_payout_mode: 'asaas', p_account_cooldown_hours: 24 }
    await db.rpc(hub, 'admin_save_finance_settings', { ...regras, p_platform_fee: 2.5 })
    const orcamento = await db.rpc(cliente, 'quote_service', { p_service_id: svc('troca_oleo'), p_lat: SLZ.lat, p_lng: SLZ.lng })
    expect(orcamento).toMatchObject({ list_price: 130, discount: 13, fee: 2.5, total: 119.5, promotion_name: 'Inauguração São Luís', region_name: 'São Luís e região metropolitana' })
    const id = await pedir('troca_oleo', false)
    expect(await detalhe(id)).toMatchObject({ price: 130, discount_amount: 13, fee_amount: 2.5, total: 119.5, commission_amount: 26, provider_net: 104 })
    // A cobrança é do total, e o desconto é custeado pela plataforma (não pelo prestador).
    await pagarPix(db, cliente, id)
    await executar(id)
    await db.rpc(cliente, 'confirm_completion', { p_id: id })
    const linhas = await db.admin<{ account: string; direction: string; amount_cents: string }>(
      `select account, direction, amount_cents from public.financial_ledger where request_id = $1 and memo like 'Conclusão%' order by id`, [id])
    expect(linhas.map((l) => [l.account, l.direction, Number(l.amount_cents)])).toEqual([
      ['customer_funds_held', 'D', 11950], ['provider_payable', 'C', 10400], ['platform_revenue', 'C', 1550],
    ])
    await db.rpc(hub, 'admin_save_finance_settings', { ...regras, p_platform_fee: 0 })
  })
  it('mudar preço não altera pedido existente; alteração direta é bloqueada', async () => {
    const id = await pedir('troca_pneu', false)
    await db.rpc(hub, 'admin_save_service', { p_id: svc('troca_pneu'), p_name: 'Troca de pneu', p_description: 'x', p_base_price: 95, p_est_minutes: 30, p_active: true, p_category_code: 'pneus' })
    expect(await detalhe(id)).toMatchObject({ price: 80, total: 80 })
    await expect(db.admin('update public.requests set price = 1 where id = $1', [id])).rejects.toMatchObject({ message: 'immutable_record' })
    const historico = await db.rpc<{ entity: string; before: { base_price: number }; after: { base_price: number } }[]>(hub, 'admin_price_history')
    expect(historico.find((h) => h.entity === 'services')).toMatchObject({ before: { base_price: 80 }, after: { base_price: 95 } })
    await db.rpc(hub, 'admin_save_service', { p_id: svc('troca_pneu'), p_name: 'Troca de pneu', p_description: 'x', p_base_price: 80, p_est_minutes: 30, p_active: true, p_category_code: 'pneus' })
    await db.rpc(cliente, 'cancel_request', { p_id: id })
  })
  it('comissão por categoria, campanha e prestador, na ordem de prioridade', async () => {
    const categoria = await db.rpc<string>(hub, 'admin_create_commission_rule', { p_name: 'Pneus 15%', p_scope: 'category', p_category_code: 'pneus', p_provider_id: null, p_percent: 15, p_starts_at: null, p_ends_at: null })
    const a = await pedir('troca_pneu', false)
    expect(await detalhe(a)).toMatchObject({ commission_percent: 15, commission_amount: 12, provider_net: 68 })
    const inicio = new Date(Date.now() - 60_000).toISOString()
    const fim = new Date(Date.now() + 3600_000).toISOString()
    const campanha = await db.rpc<string>(hub, 'admin_create_commission_rule', { p_name: 'Campanha 10%', p_scope: 'campaign', p_category_code: null, p_provider_id: null, p_percent: 10, p_starts_at: inicio, p_ends_at: fim })
    const b = await pedir('troca_pneu', false)
    expect(await detalhe(b)).toMatchObject({ commission_percent: 10 })
    const prestador = await db.rpc<string>(hub, 'admin_create_commission_rule', { p_name: 'Parceiro fundador', p_scope: 'provider', p_category_code: null, p_provider_id: ze.sub, p_percent: 5, p_starts_at: null, p_ends_at: null })
    // A regra do prestador vale no aceite (a contratação) e aparece na oferta.
    await pagarPix(db, cliente, b)
    const [oferta] = await db.rpc<{ id: string; provider_net: number }[]>(ze, 'open_requests')
    expect(oferta).toMatchObject({ id: b, provider_net: 76 })
    await db.rpc(ze, 'accept_request', { p_id: b })
    expect(await detalhe(b)).toMatchObject({ commission_percent: 5, provider_net: 76 })
    // Regra não se edita: encerra-se. Pedido já contratado não muda.
    await expect(db.admin('update public.commission_rules set percent = 1 where id = $1', [prestador])).rejects.toMatchObject({ message: 'immutable_record' })
    for (const r of [categoria, campanha, prestador]) await db.rpc(hub, 'admin_end_commission_rule', { p_id: r })
    expect(await detalhe(b)).toMatchObject({ commission_percent: 5 })
    await db.rpc(ze, 'withdraw_request', { p_id: b, p_reason: 'Teste de desistência justificada' })
    expect(await detalhe(b)).toMatchObject({ commission_percent: 10 }) // volta à comissão registrada na criação
    await db.rpc(cliente, 'cancel_request', { p_id: a })
    await db.rpc(cliente, 'cancel_request', { p_id: b })
  })
})

describe('conclusão, disputa e repasse', () => {
  it('o repasse é agendado 7 dias depois da conclusão confirmada', async () => {
    const id = await concluido()
    const pedido = await detalhe(id)
    expect(pedido).toMatchObject({ financial_status: 'payout_scheduled', payout: { status: 'scheduled', amount: 64 } })
    const dias = (new Date(pedido.payout!.scheduled_for).getTime() - Date.now()) / 86400_000
    expect(dias).toBeGreaterThan(6.99)
    expect(dias).toBeLessThan(7.01)
  })
  it('sem resposta do cliente, a conclusão é confirmada automaticamente no prazo', async () => {
    const id = await pedir()
    await executar(id)
    expect(await detalhe(id)).toMatchObject({ financial_status: 'service_completed', payout: null })
    await db.admin(`update public.requests set completion_deadline = now() - interval '1 minute' where id = $1`, [id])
    await db.rpc(service, 'finance_tick')
    expect(await detalhe(id)).toMatchObject({ financial_status: 'payout_scheduled', payout: { status: 'scheduled' } })
  })
  it('disputa retém o repasse; decisão a favor do cliente estorna', async () => {
    const id = await concluido()
    await expect(db.rpc(cliente, 'open_dispute', { p_id: id, p_reason: 'curto' })).rejects.toMatchObject({ message: 'reason_required' })
    await db.rpc(cliente, 'open_dispute', { p_id: id, p_reason: 'O pneu trocado voltou a esvaziar no mesmo dia.' })
    expect(await detalhe(id)).toMatchObject({ financial_status: 'disputed', payout: { status: 'on_hold' } })
    await vencer(id)
    const [d] = await db.rpc<{ id: string; request_id: string }[]>(financeiro, 'finance_disputes')
    expect(d.request_id).toBe(id)
    await db.rpc(financeiro, 'finance_resolve_dispute', { p_dispute_id: d.id, p_outcome: 'customer', p_note: 'Serviço refeito por outro prestador; cliente reembolsado.' })
    expect(await detalhe(id)).toMatchObject({ financial_status: 'refund_pending', payout: { status: 'cancelled' } })
    expect(await saldo('provider_payable')).toBeLessThanOrEqual(0)
    expect(await balancete()).toBe(0)
  })
  it('disputa decidida a favor do prestador libera o repasse', async () => {
    const id = await pedir()
    await executar(id)
    await db.rpc(cliente, 'open_dispute', { p_id: id, p_reason: 'Acho que a calibragem ficou errada no pneu dianteiro.' })
    const d = (await db.rpc<{ id: string; request_id: string; status: string }[]>(financeiro, 'finance_disputes')).find((x) => x.request_id === id)!
    await db.rpc(financeiro, 'finance_resolve_dispute', { p_dispute_id: d.id, p_outcome: 'provider', p_note: 'Fotos do prestador mostram a calibragem correta.' })
    expect(await detalhe(id)).toMatchObject({ financial_status: 'payout_scheduled', payout: { status: 'scheduled' } })
  })
})

describe('conta Pix do prestador', () => {
  it('chave CPF precisa ser a do credenciamento; conta nova passa por conferência e carência', async () => {
    await expect(db.rpc(ze, 'save_payment_account', { p_pix_key_type: 'CPF', p_pix_key: CPF_TESTE, p_holder_name: 'Zé Prestador' })).rejects.toMatchObject({ message: 'key_not_owner' })
    await expect(db.rpc(ze, 'save_payment_account', { p_pix_key_type: 'EVP', p_pix_key: 'nao-e-chave', p_holder_name: 'Zé Prestador' })).rejects.toMatchObject({ message: 'invalid_key' })
    await db.rpc(ze, 'save_payment_account', { p_pix_key_type: 'CPF', p_pix_key: '111.444.777-35', p_holder_name: 'Zé Prestador' })
    const [conta] = await db.rpc<{ id: string; status: string; holder_doc: string }[]>(financeiro, 'finance_accounts')
    expect(conta).toMatchObject({ status: 'pending_review', holder_doc: ZE_CPF })
    await expect(db.rpc(ze, 'finance_review_account', { p_account_id: conta.id, p_approve: true })).rejects.toMatchObject(denied)
    await db.rpc(financeiro, 'finance_review_account', { p_account_id: conta.id, p_approve: true })
    const fin = await db.rpc<{ account: { usable_from: string; pix_key_masked: string } }>(ze, 'provider_finance')
    expect(new Date(fin.account.usable_from).getTime()).toBeGreaterThan(Date.now() + 23 * 3600_000)
    expect(fin.account.pix_key_masked).not.toContain('444')
  })
  it('na carência, o repasse vencido não sai', async () => {
    const id = await concluido()
    await db.admin(`update public.payouts set scheduled_for = now() - interval '1 minute' where request_id = $1`, [id])
    const fila = await db.rpc<Claim[]>(service, 'payout_claim')
    expect(fila).toEqual([])
  })
})

describe('processamento de repasses', () => {
  it('repasse vencido é transferido uma vez e conciliado', async () => {
    const id = await concluido()
    await vencer(id)
    const [a, b] = await Promise.all([db.rpc<Claim[]>(service, 'payout_claim'), db.rpc<Claim[]>(service, 'payout_claim')])
    const todos = [...a, ...b]
    const meus = todos.filter((c) => c.amount_cents === 6400)
    // Sem duplicidade entre processos concorrentes.
    expect(new Set(todos.map((c) => c.payout_id)).size).toBe(todos.length)
    expect(meus.length).toBeGreaterThan(0)
    const [{ id: payoutId }] = await db.admin<{ id: string }>('select id from public.payouts where request_id = $1', [id])
    const claim = todos.find((c) => c.payout_id === payoutId)!
    expect(claim).toMatchObject({ pix_key: ZE_CPF, pix_key_type: 'CPF' })
    expect(await detalhe(id)).toMatchObject({ financial_status: 'payout_processing' })
    // Validação de saque: aprova a transferência certa, recusa valor ou chave diferente e uma segunda transferência.
    expect(await db.rpc(service, 'payout_validate_transfer', { p_transfer_id: 'tr_1', p_value_cents: 6400, p_external_reference: payoutId, p_pix_key: ZE_CPF }))
      .toMatchObject({ approved: true })
    expect(await db.rpc(service, 'payout_validate_transfer', { p_transfer_id: 'tr_2', p_value_cents: 6400, p_external_reference: payoutId, p_pix_key: ZE_CPF }))
      .toMatchObject({ approved: false })
    expect(await db.rpc(service, 'payout_validate_transfer', { p_transfer_id: 'tr_x', p_value_cents: 999999, p_external_reference: null, p_pix_key: '000' }))
      .toMatchObject({ approved: false })
    expect(await db.rpc(service, 'payout_transfer_created', { p_payout_id: payoutId, p_claim_token: claim.claim_token, p_external_id: 'tr_1', p_status: 'PENDING' }))
      .toMatchObject({ result: 'ok' })
    // Token antigo (processo atrasado) não mexe em nada.
    expect(await db.rpc(service, 'payout_transfer_created', { p_payout_id: payoutId, p_claim_token: '00000000-0000-0000-0000-000000000000', p_external_id: 'tr_9', p_status: 'PENDING' }))
      .toMatchObject({ result: 'stale' })
    // Eventos fora de ordem: DONE, depois PENDING atrasado.
    await db.rpc(service, 'payout_sync_transfer', { p_external_id: 'tr_1', p_external_reference: payoutId, p_status: 'DONE', p_fee_cents: 0 })
    await db.rpc(service, 'payout_sync_transfer', { p_external_id: 'tr_1', p_external_reference: payoutId, p_status: 'PENDING' })
    expect(await db.rpc(service, 'payout_sync_transfer', { p_external_id: 'tr_1', p_external_reference: payoutId, p_status: 'DONE' })).toMatchObject({ result: 'already' })
    expect(await detalhe(id)).toMatchObject({ financial_status: 'payout_completed', payout: { status: 'completed' } })
    const pagos = await db.admin(`select count(*)::int as n from public.financial_ledger where payout_id = $1 and account = 'provider_payable' and direction = 'D'`, [payoutId])
    expect(pagos).toEqual([{ n: 1 }])
    // Os demais repasses reservados neste teste falham de forma recuperável.
    for (const c of todos.filter((x) => x.payout_id !== payoutId)) {
      await db.rpc(service, 'payout_attempt_failed', { p_payout_id: c.payout_id, p_claim_token: c.claim_token, p_error: 'teste', p_retryable: true, p_uncertain: false })
    }
    expect(await balancete()).toBe(0)
  })
  it('falha na transferência: novas tentativas com espera e, no limite, alerta', async () => {
    const id = await concluido()
    await vencer(id)
    const [{ id: payoutId }] = await db.admin<{ id: string }>('select id from public.payouts where request_id = $1', [id])
    await db.admin(`update public.payouts set status = 'failed', next_attempt_at = now() + interval '1 day', final_failure = true where status in ('scheduled', 'failed') and id <> $1`, [payoutId])
    for (let tentativa = 1; tentativa <= 5; tentativa++) {
      await db.admin(`update public.payouts set next_attempt_at = now() - interval '1 second' where id = $1`, [payoutId])
      const [claim] = (await db.rpc<Claim[]>(service, 'payout_claim')).filter((c) => c.payout_id === payoutId)
      expect(claim).toBeDefined()
      await db.rpc(service, 'payout_attempt_failed', { p_payout_id: payoutId, p_claim_token: claim.claim_token, p_error: 'Chave Pix não encontrada', p_retryable: true, p_uncertain: false })
    }
    const [po] = await db.admin<{ status: string; final_failure: boolean; attempts: number }>('select status, final_failure, attempts from public.payouts where id = $1', [payoutId])
    expect(po).toMatchObject({ status: 'failed', final_failure: true, attempts: 5 })
    expect(await db.rpc(service, 'payout_claim')).toEqual([])
    expect(await detalhe(id)).toMatchObject({ financial_status: 'payout_failed' })
    expect((await db.rpc<{ title: string }[]>(ze, 'my_notifications')).map((n) => n.title)).toContain('Repasse não concluído')
    await db.rpc(financeiro, 'finance_retry_payout', { p_payout_id: payoutId })
    expect(await detalhe(id)).toMatchObject({ financial_status: 'payout_scheduled', payout: { status: 'scheduled' } })
  })
  it('sem resposta do provedor, o repasse não é tentado de novo até a conciliação', async () => {
    const [{ request_id: id, id: payoutId }] = await db.admin<{ request_id: string; id: string }>(`select request_id, id from public.payouts where status = 'scheduled' order by created_at desc limit 1`)
    await vencer(id)
    const [claim] = (await db.rpc<Claim[]>(service, 'payout_claim')).filter((c) => c.payout_id === payoutId)
    await db.rpc(service, 'payout_attempt_failed', { p_payout_id: payoutId, p_claim_token: claim.claim_token, p_error: 'timeout', p_retryable: true, p_uncertain: true })
    expect((await db.rpc<Claim[]>(service, 'payout_claim')).map((c) => c.payout_id)).not.toContain(payoutId)
    await db.admin(`update public.payouts set updated_at = now() - interval '11 minutes' where id = $1`, [payoutId])
    expect((await db.rpc<{ payout_id: string; uncertain: boolean }[]>(service, 'payouts_to_reconcile')).find((p) => p.payout_id === payoutId)).toMatchObject({ uncertain: true })
    await expect(db.rpc(financeiro, 'finance_resolve_uncertain_payout', { p_payout_id: payoutId, p_sent: true, p_transfer_id: '', p_note: 'Conferido no painel do provedor' }))
      .rejects.toMatchObject({ message: 'transfer_required' })
    await db.rpc(financeiro, 'finance_resolve_uncertain_payout', { p_payout_id: payoutId, p_sent: true, p_transfer_id: 'tr_manual_1', p_note: 'Transferência localizada no painel do provedor' })
    expect(await detalhe(id)).toMatchObject({ financial_status: 'payout_completed' })
    // Estorno depois do repasse: o prestador passa a dever (conta a receber).
    await db.rpc(financeiro, 'finance_request_refund', { p_request_id: id, p_note: 'Cliente comprovou cobrança indevida.' })
    expect(await saldo('provider_receivable')).toBeGreaterThan(0)
    expect(await balancete()).toBe(0)
  })
  it('estorno com repasse em processamento é recusado', async () => {
    const id = await concluido()
    await vencer(id)
    await db.admin(`update public.payouts set status = 'failed', final_failure = true where status = 'scheduled' and request_id <> $1`, [id])
    const [claim] = await db.rpc<Claim[]>(service, 'payout_claim')
    await expect(db.rpc(financeiro, 'finance_request_refund', { p_request_id: id, p_note: 'Tentativa durante o processamento.' }))
      .rejects.toMatchObject({ message: 'payout_in_progress' })
    await db.rpc(service, 'payout_transfer_created', { p_payout_id: claim.payout_id, p_claim_token: claim.claim_token, p_external_id: 'tr_inst', p_status: 'DONE', p_fee_cents: 0 })
    expect(await detalhe(id)).toMatchObject({ financial_status: 'payout_completed' })
  })
})

describe('razão e auditoria', () => {
  it('o razão não aceita alteração nem exclusão e fecha em zero', async () => {
    await expect(db.admin('update public.financial_ledger set amount_cents = 1')).rejects.toMatchObject({ message: 'immutable_record' })
    await expect(db.admin('delete from public.financial_ledger')).rejects.toMatchObject({ message: 'immutable_record' })
    await expect(db.admin('delete from public.audit_logs')).rejects.toMatchObject({ message: 'immutable_record' })
    await expect(db.admin(`insert into public.financial_ledger (journal_id, account, direction, amount_cents, memo) values (gen_random_uuid(), 'cash_gateway', 'D', 10, 'x')`))
      .rejects.toMatchObject({ message: 'ledger_unbalanced' })
    const r = await db.rpc<{ trial_balance: number }>(financeiro, 'finance_reconciliation')
    expect(Number(r.trial_balance)).toBe(0)
  })
  it('mudanças de regra e de repasse ficam na auditoria com o autor', async () => {
    const log = await db.rpc<{ entity: string; actor: string | null }[]>(financeiro, 'finance_audit', { p_entity: 'commission_rules' })
    expect(log[0]).toMatchObject({ entity: 'commission_rules', actor: 'Equipe HUB' })
    const repasses = await db.rpc<{ entity: string }[]>(financeiro, 'finance_audit', { p_entity: 'payouts' })
    expect(repasses.length).toBeGreaterThan(0)
  })
  it('o painel reflete volume, receita e repasses', async () => {
    const d = await db.rpc<{ volume: number; revenue: number; payouts: { completed_period_count: number }; by_category: unknown[] }>(financeiro, 'finance_dashboard')
    expect(d.volume).toBeGreaterThan(0)
    expect(d.revenue).toBeGreaterThan(0)
    expect(d.payouts.completed_period_count).toBeGreaterThan(0)
    expect(d.by_category.length).toBeGreaterThan(0)
  })
})

describe('e-mails', () => {
  it('fatos financeiros põem e-mails na fila, uma vez cada', async () => {
    const fila = await db.admin<{ template: string }>(`select distinct template from public.notification_logs`)
    expect(fila.map((f) => f.template)).toEqual(expect.arrayContaining(['pagamento_confirmado', 'servico_concluido', 'repasse_agendado', 'repasse_realizado', 'alerta_financeiro', 'conta_pix_alterada']))
    const dup = await db.admin(`select idempotency_key from public.notification_logs group by 1 having count(*) > 1`)
    expect(dup).toEqual([])
  })
  it('envio com erro temporário volta para a fila com espera; erro definitivo encerra', async () => {
    const lote = await db.rpc<{ id: number; attempts: number }[]>(service, 'email_claim', { p_limit: 2 })
    expect(lote).toHaveLength(2)
    expect(await db.rpc<{ id: number }[]>(service, 'email_claim', { p_limit: 100 })).not.toContainEqual(expect.objectContaining({ id: lote[0].id }))
    await db.rpc(service, 'email_result', { p_id: lote[0].id, p_outcome: 'retry', p_error: '429 rate limit' })
    await db.rpc(service, 'email_result', { p_id: lote[1].id, p_outcome: 'failed', p_error: '422 invalid to' })
    const linhas = await db.admin<{ id: string; status: string; next_attempt_at: Date }>('select id, status, next_attempt_at from public.notification_logs where id = any($1::bigint[]) order by id', [[lote[0].id, lote[1].id]])
    expect(linhas[0].status).toBe('queued')
    expect(new Date(linhas[0].next_attempt_at).getTime()).toBeGreaterThan(Date.now())
    expect(linhas[1].status).toBe('failed')
  })
})
