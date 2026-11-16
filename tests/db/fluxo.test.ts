import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { TestDb, PNG_1PX, anon, service, type TestUser } from './harness'

/**
 * O caminho completo de um atendimento e as garantias do contrato de
 * credenciamento que o sistema precisa cumprir na prática.
 */
let db: TestDb
let cliente: TestUser
let ze: TestUser
let outro: TestUser
let hub: TestUser
let servicos: { id: string; code: string; base_price: number }[]
let veiculo: string

const denied = { message: 'permission_denied', code: '42501' }
const SLZ = { lat: -2.5307, lng: -44.3068 }

type Pedido = {
  id: string; status: string; price: number; total: number; commission_amount: number; provider_net: number
  customer: { name: string; phone: string } | null; vehicle: { plate?: string }; payout_status: string
  extras: { id: string; status: string }[]; provider: { rating: { average: number | null; count: number } } | null
}

async function credenciar(user: TestUser, codes: string[], aprovar = true) {
  const docs = await db.rpc<unknown[]>(user, 'my_documents')
  if (docs.length === 0) {
    await db.rpc(user, 'upload_document', { p_kind: 'identity', p_file_name: 'cnh.png', p_mime: 'image/png', p_content_base64: PNG_1PX })
  }
  await db.rpc(user, 'provider_apply', {
    p_doc_type: 'cpf', p_doc_number: '123.456.789-09', p_legal_name: user.name, p_city: 'São Luís',
    p_experience: 'Dez anos de borracharia móvel', p_radius_km: 20,
    p_service_ids: servicos.filter((s) => codes.includes(s.code)).map((s) => s.id), p_lat: SLZ.lat, p_lng: SLZ.lng,
  })
  if (aprovar) {
    await db.rpc(hub, 'admin_decide_provider', {
      p_id: user.sub, p_approved_service_ids: servicos.filter((s) => codes.includes(s.code)).map((s) => s.id),
    })
  }
}
async function aceitarContrato(user: TestUser) {
  const contrato = await db.rpc<{ id: string }>(user, 'current_contract')
  await db.rpc(user, 'accept_contract', { p_version_id: contrato.id, p_ip: '203.0.113.7', p_user_agent: 'teste' })
}
const pedir = (code: string, onde = SLZ) =>
  db.rpc<string>(cliente, 'create_request', {
    p_service_id: servicos.find((s) => s.code === code)!.id, p_vehicle_id: veiculo,
    p_address: 'Av. dos Holandeses, 100 — Calhau', p_lat: onde.lat, p_lng: onde.lng,
  })

beforeAll(async () => {
  db = await TestDb.create()
  hub = await db.createUser('hub_admin', 'Equipe HUB')
  cliente = await db.createUser('customer', 'Carla Cliente')
  ze = await db.createUser('provider', 'Zé Prestador')
  outro = await db.createUser('provider', 'Outro Prestador')
  servicos = await db.rpc(cliente, 'list_services')
  veiculo = await db.rpc<string>(cliente, 'save_vehicle', { p_plate: 'abc-1d23', p_brand: 'Fiat', p_model: 'Argo', p_year: 2021 })
})
afterAll(async () => {
  await db.destroy()
})

describe('acesso', () => {
  it('ninguém lê tabelas direto, nem autenticado', async () => {
    for (const table of ['profiles', 'requests', 'providers', 'contract_acceptances', 'vehicles']) {
      await expect(db.query(cliente, `select * from public.${table}`)).rejects.toMatchObject({ code: '42501' })
    }
  })
  it('anônimo não chama nenhuma função', async () => {
    await expect(db.rpc(anon, 'list_services')).rejects.toMatchObject({ code: '42501' })
    await expect(db.rpc(anon, 'my_access')).rejects.toMatchObject({ code: '42501' })
  })
  it('cada papel só usa as próprias funções', async () => {
    await expect(db.rpc(cliente, 'admin_overview')).rejects.toMatchObject(denied)
    await expect(db.rpc(ze, 'admin_providers')).rejects.toMatchObject(denied)
    await expect(db.rpc(cliente, 'open_requests')).rejects.toMatchObject(denied)
    await expect(db.rpc(ze, 'my_requests')).rejects.toMatchObject(denied)
    await expect(db.rpc(cliente, 'promote_hub_admin', { p_email: 'x@y.z', p_full_name: 'X', p_phone: '1' })).rejects.toMatchObject({ code: '42501' })
  })
  it('o cadastro não aceita o papel de administrador', async () => {
    const id = (await db.admin<{ id: string }>(`insert into auth.users (email) values ('novo@teste.invalid') returning id`))[0].id
    await expect(db.rpc({ sub: id, role: 'authenticated' }, 'register_profile', { p_full_name: 'Esperto', p_phone: '98999990000', p_role: 'hub_admin', p_terms_version: 'teste' }))
      .rejects.toMatchObject({ message: 'invalid_role' })
  })
})

describe('credenciamento e contrato', () => {
  it('sem documento de identificação o credenciamento não é enviado', async () => {
    await expect(db.rpc(ze, 'provider_apply', {
      p_doc_type: 'cpf', p_doc_number: '12345678909', p_legal_name: 'Zé Prestador', p_city: 'São Luís', p_experience: '',
      p_radius_km: 20, p_service_ids: [servicos[0].id],
    })).rejects.toMatchObject({ message: 'identity_required' })
    await expect(db.rpc(ze, 'upload_document', { p_kind: 'identity', p_file_name: 'x.exe', p_mime: 'application/x-msdownload', p_content_base64: PNG_1PX }))
      .rejects.toMatchObject({ message: 'invalid_file' })
  })
  it('sem aprovação e sem contrato aceito, o prestador não fica disponível', async () => {
    await expect(db.rpc(ze, 'set_online', { p_online: true })).rejects.toMatchObject({ message: 'not_approved' })
    await credenciar(ze, ['troca_pneu', 'troca_oleo'])
    await expect(db.rpc(ze, 'set_online', { p_online: true })).rejects.toMatchObject({ message: 'contract_required' })
  })
  it('o aceite guarda quem, quando, de onde e a impressão digital do texto', async () => {
    await aceitarContrato(ze)
    const [aceite] = await db.admin(
      `select a.signer_name, a.signer_doc, a.ip, a.commission_percent, a.body_sha256 = v.body_sha256 as integro,
              v.body_sha256 = encode(extensions.digest(v.body, 'sha256'), 'hex') as confere
       from public.contract_acceptances a join public.contract_versions v on v.id = a.contract_version_id where a.provider_id = $1`, [ze.sub])
    expect(aceite).toMatchObject({ signer_name: 'Zé Prestador', signer_doc: '12345678909', ip: '203.0.113.7', integro: true, confere: true })
    expect(Number(aceite.commission_percent)).toBe(20)
    await db.rpc(ze, 'set_online', { p_online: true, p_lat: SLZ.lat, p_lng: SLZ.lng })
  })
  it('recusado pela HUB precisa de motivo e não recebe pedidos', async () => {
    await credenciar(outro, ['troca_pneu'], false)
    await expect(db.rpc(hub, 'admin_decide_provider', { p_id: outro.sub, p_approved_service_ids: [] })).rejects.toMatchObject({ message: 'note_required' })
    await db.rpc(hub, 'admin_decide_provider', { p_id: outro.sub, p_approved_service_ids: [], p_note: 'Documento ilegível, reenviar.' })
    await expect(db.rpc(outro, 'set_online', { p_online: true })).rejects.toMatchObject({ message: 'not_approved' })
    // Reenvia e é aprovado.
    await credenciar(outro, ['troca_pneu'])
    await aceitarContrato(outro)
    await db.rpc(outro, 'set_online', { p_online: true, p_lat: SLZ.lat, p_lng: SLZ.lng })
  })
})

describe('atendimento do início ao fim', () => {
  let pedido: string

  it('a oferta mostra preço, comissão e líquido, sem dados pessoais do cliente', async () => {
    pedido = await pedir('troca_pneu')
    const [oferta] = await db.rpc<Pedido[]>(ze, 'open_requests')
    expect(oferta).toMatchObject({ id: pedido, price: 80, commission_amount: 16, provider_net: 64, customer: null })
    expect(oferta.vehicle.plate).toBeUndefined()
  })
  it('pedido fora do raio ou de serviço sem habilitação não aparece', async () => {
    const longe = await pedir('troca_pneu', { lat: -3.7319, lng: -38.5267 }) // Fortaleza
    const semHabilitacao = await pedir('alinhamento')
    const ids = (await db.rpc<Pedido[]>(ze, 'open_requests')).map((p) => p.id)
    expect(ids).toEqual([pedido])
    await expect(db.rpc(ze, 'accept_request', { p_id: longe })).rejects.toMatchObject({ message: 'request_taken' })
    await expect(db.rpc(ze, 'request_detail', { p_id: semHabilitacao })).rejects.toMatchObject(denied)
    await db.rpc(cliente, 'cancel_request', { p_id: longe })
    await db.rpc(cliente, 'cancel_request', { p_id: semHabilitacao })
  })
  it('recusar não pune: o pedido some da lista e a nota não muda', async () => {
    await db.rpc(outro, 'decline_request', { p_id: pedido })
    expect(await db.rpc(outro, 'open_requests')).toEqual([])
    const home = await db.rpc<{ status: string; rating: { count: number } }>(outro, 'provider_home')
    expect(home).toMatchObject({ status: 'approved', rating: { count: 0 } })
  })
  it('só um prestador fica com o pedido', async () => {
    await db.rpc(ze, 'accept_request', { p_id: pedido })
    await db.admin('delete from public.request_declines where request_id = $1', [pedido])
    await expect(db.rpc(outro, 'accept_request', { p_id: pedido })).rejects.toMatchObject({ message: 'request_taken' })
    await expect(db.rpc(outro, 'request_detail', { p_id: pedido })).rejects.toMatchObject(denied)
    const visto = await db.rpc<Pedido>(ze, 'request_detail', { p_id: pedido })
    expect(visto.customer).toMatchObject({ name: 'Carla Cliente' })
    expect(visto.vehicle.plate).toBe('ABC1D23')
  })
  it('as etapas seguem a ordem e o adicional depende do cliente', async () => {
    await expect(db.rpc(ze, 'advance_request', { p_id: pedido, p_to: 'completed' })).rejects.toMatchObject({ message: 'invalid_step' })
    await db.rpc(ze, 'advance_request', { p_id: pedido, p_to: 'en_route' })
    await db.rpc(ze, 'advance_request', { p_id: pedido, p_to: 'in_progress' })
    await expect(db.rpc(cliente, 'cancel_request', { p_id: pedido })).rejects.toMatchObject({ message: 'cannot_cancel' })
    const extra = await db.rpc<string>(ze, 'propose_extra', { p_id: pedido, p_description: 'Válvula nova', p_price: 20 })
    const recusado = await db.rpc<string>(ze, 'propose_extra', { p_id: pedido, p_description: 'Calibragem com nitrogênio', p_price: 30 })
    await expect(db.rpc(ze, 'advance_request', { p_id: pedido, p_to: 'completed' })).rejects.toMatchObject({ message: 'extras_pending' })
    await expect(db.rpc(ze, 'decide_extra', { p_extra_id: extra, p_approve: true })).rejects.toMatchObject(denied)
    await db.rpc(cliente, 'decide_extra', { p_extra_id: extra, p_approve: true })
    await db.rpc(cliente, 'decide_extra', { p_extra_id: recusado, p_approve: false })
    await db.rpc(ze, 'advance_request', { p_id: pedido, p_to: 'completed' })
    const fim = await db.rpc<Pedido>(cliente, 'request_detail', { p_id: pedido })
    expect(fim).toMatchObject({ status: 'completed', total: 100, commission_amount: 20, provider_net: 80 })
  })
  it('pagamento agenda o repasse; avaliação entra na nota; a HUB repassa', async () => {
    await expect(db.rpc(cliente, 'create_request', { p_service_id: servicos[0].id, p_vehicle_id: veiculo, p_address: 'Rua Um, 10' }))
      .rejects.toMatchObject({ message: 'payment_pending' })
    await db.rpc(cliente, 'pay_request', { p_id: pedido })
    await expect(db.rpc(cliente, 'pay_request', { p_id: pedido })).rejects.toMatchObject({ message: 'cannot_pay' })
    await db.rpc(cliente, 'review_request', { p_id: pedido, p_rating: 5, p_comment: 'Rápido e cuidadoso' })
    await expect(db.rpc(cliente, 'review_request', { p_id: pedido, p_rating: 1 })).rejects.toMatchObject({ message: 'already_reviewed' })
    const ganhos = await db.rpc<{ summary: Record<string, number> }>(ze, 'provider_jobs')
    expect(ganhos.summary).toMatchObject({ completed: 1, to_receive: 80, received: 0 })
    await expect(db.rpc(ze, 'admin_mark_payout', { p_request_id: pedido })).rejects.toMatchObject(denied)
    await db.rpc(hub, 'admin_mark_payout', { p_request_id: pedido })
    expect((await db.rpc<{ summary: Record<string, number> }>(ze, 'provider_jobs')).summary).toMatchObject({ to_receive: 0, received: 80 })
    const geral = await db.rpc<{ requests: Record<string, number>; rating: { average: number } }>(hub, 'admin_overview')
    expect(geral.requests).toMatchObject({ completed: 1, gross: 100, commission: 20 })
    expect(geral.rating.average).toBe(5)
  })
  it('mudar a comissão vale só para pedidos novos', async () => {
    const antigo = await pedir('troca_oleo')
    await db.rpc(hub, 'admin_save_settings', { p_commission_percent: 15, p_payout_days: 3, p_search_radius_km: 25 })
    const novo = await pedir('troca_oleo')
    expect(await db.rpc<Pedido>(cliente, 'request_detail', { p_id: antigo })).toMatchObject({ commission_amount: 24, provider_net: 96 })
    expect(await db.rpc<Pedido>(cliente, 'request_detail', { p_id: novo })).toMatchObject({ commission_amount: 18, provider_net: 102 })
    await db.rpc(cliente, 'cancel_request', { p_id: novo })
  })
  it('desistir depois do aceite exige justificativa e devolve o pedido à busca', async () => {
    const [aberto] = await db.rpc<Pedido[]>(ze, 'open_requests')
    await db.rpc(ze, 'accept_request', { p_id: aberto.id })
    await expect(db.rpc(ze, 'withdraw_request', { p_id: aberto.id, p_reason: 'não' })).rejects.toMatchObject({ message: 'reason_required' })
    await db.rpc(ze, 'withdraw_request', { p_id: aberto.id, p_reason: 'Pneu do meu veículo furou no caminho' })
    expect(await db.rpc<Pedido>(cliente, 'request_detail', { p_id: aberto.id })).toMatchObject({ status: 'searching', provider: null })
    await db.rpc(cliente, 'cancel_request', { p_id: aberto.id })
  })
})

describe('suspensão com contestação', () => {
  it('exige motivo, tira o prestador do ar e permite contestar e rever', async () => {
    await expect(db.rpc(hub, 'admin_suspend_provider', { p_id: ze.sub, p_reason: 'ruim' })).rejects.toMatchObject({ message: 'reason_required' })
    await db.rpc(hub, 'admin_suspend_provider', { p_id: ze.sub, p_reason: 'Equipamento sem condição de segurança', p_precautionary: true })
    await expect(db.rpc(ze, 'set_online', { p_online: true })).rejects.toMatchObject({ message: 'not_approved' })
    const home = await db.rpc<{ suspension: { id: string; reason: string } }>(ze, 'provider_home')
    expect(home.suspension.reason).toContain('Equipamento')
    await db.rpc(ze, 'contest_suspension', { p_id: home.suspension.id, p_text: 'O macaco hidráulico foi trocado ontem, envio a nota fiscal.' })
    await db.rpc(hub, 'admin_resolve_suspension', { p_id: home.suspension.id, p_lift: true, p_note: 'Nota fiscal conferida, equipamento regular.' })
    await db.rpc(ze, 'set_online', { p_online: true })
  })
  it('o prestador encerra o credenciamento quando quiser', async () => {
    await db.rpc(outro, 'close_credentialing')
    expect(await db.rpc(outro, 'provider_home')).toMatchObject({ status: 'closed', online: false })
  })
})

describe('documentos', () => {
  it('só o dono e a HUB abrem o arquivo; aprovado não remove', async () => {
    const [doc] = await db.rpc<{ id: string; size: number }[]>(ze, 'my_documents')
    expect(doc.size).toBeGreaterThan(0)
    expect(await db.rpc<{ content_base64: string }>(ze, 'get_document', { p_id: doc.id })).toMatchObject({ mime: 'image/png' })
    expect((await db.rpc<{ content_base64: string }>(hub, 'get_document', { p_id: doc.id })).content_base64.replace(/\s/g, '')).toBe(PNG_1PX)
    await expect(db.rpc(cliente, 'get_document', { p_id: doc.id })).rejects.toMatchObject(denied)
    await expect(db.rpc(outro, 'get_document', { p_id: doc.id })).rejects.toMatchObject(denied)
    await expect(db.rpc(ze, 'delete_document', { p_id: doc.id })).rejects.toMatchObject({ message: 'documents_locked' })
    const detalhe = await db.rpc<{ documents: unknown[] }>(hub, 'admin_provider', { p_id: ze.sub })
    expect(detalhe.documents).toHaveLength(1)
  })
})

describe('avisos', () => {
  it('cada parte recebe os avisos do que lhe diz respeito', async () => {
    const titulos = async (user: TestUser) => (await db.rpc<{ title: string }[]>(user, 'my_notifications')).map((n) => n.title)
    expect(await titulos(cliente)).toEqual(expect.arrayContaining(['Prestador confirmado', 'Prestador a caminho', 'Orçamento adicional', 'Serviço concluído', 'Buscando outro prestador']))
    expect(await titulos(ze)).toEqual(expect.arrayContaining(['Credenciamento aprovado', 'Novo pedido: Troca de pneu', 'Adicional aprovado', 'Pagamento confirmado', 'Repasse realizado', 'Credenciamento suspenso', 'Suspensão encerrada']))
    expect(await titulos(hub)).toEqual(expect.arrayContaining(['Credenciamento para analisar', 'Suspensão contestada']))
    // Ler marca como lido.
    expect((await db.rpc<{ unread: number }>(ze, 'my_access')).unread).toBe(0)
  })
  it('a fila de push é só do servidor e entrega cada aviso uma vez', async () => {
    await expect(db.rpc(ze, 'push_take')).rejects.toMatchObject({ code: '42501' })
    await db.rpc(service, 'push_take') // esvazia o que ficou dos testes anteriores
    await db.rpc(cliente, 'save_push_subscription', { p_endpoint: 'https://push.example.invalid/abc', p_p256dh: 'p'.repeat(87), p_auth: 'a'.repeat(22) })
    const id = await pedir('troca_oleo')
    await db.rpc(ze, 'accept_request', { p_id: id })
    const fila = await db.rpc<{ title: string; subscriptions: { endpoint: string }[] }[]>(service, 'push_take')
    expect(fila).toHaveLength(1)
    expect(fila[0]).toMatchObject({ title: 'Prestador confirmado', subscriptions: [{ endpoint: 'https://push.example.invalid/abc' }] })
    expect(await db.rpc(service, 'push_take')).toEqual([])
    await db.rpc(service, 'push_gone', { p_endpoint: 'https://push.example.invalid/abc' })
    await db.rpc(ze, 'withdraw_request', { p_id: id, p_reason: 'Teste de desistência justificada' })
    await db.rpc(cliente, 'cancel_request', { p_id: id })
  })
})

describe('pagamento por Pix confirmado pela HUB', () => {
  it('com chave Pix, o cliente avisa e só a HUB confirma', async () => {
    await expect(db.rpc(hub, 'admin_save_pix', { p_pix_key: 'pix@hub.invalid', p_pix_holder: '' })).rejects.toMatchObject({ message: 'invalid_pix' })
    await db.rpc(hub, 'admin_save_pix', { p_pix_key: 'pix@hub.invalid', p_pix_holder: 'HUB Tecnologia Ltda' })
    expect(await db.rpc(cliente, 'payment_info')).toMatchObject({ mode: 'pix', pix_key: 'pix@hub.invalid' })
    const id = await pedir('troca_pneu')
    await db.rpc(ze, 'accept_request', { p_id: id })
    for (const to of ['en_route', 'in_progress', 'completed']) await db.rpc(ze, 'advance_request', { p_id: id, p_to: to })
    await expect(db.rpc(cliente, 'pay_request', { p_id: id })).rejects.toMatchObject({ message: 'pix_required' })
    await db.rpc(cliente, 'claim_payment', { p_id: id })
    await expect(db.rpc(cliente, 'claim_payment', { p_id: id })).rejects.toMatchObject({ message: 'cannot_pay' })
    expect(await db.rpc(cliente, 'request_detail', { p_id: id })).toMatchObject({ payment_status: 'pending' })
    await expect(db.rpc(cliente, 'admin_confirm_payment', { p_request_id: id })).rejects.toMatchObject(denied)
    expect((await db.rpc<{ payments_to_confirm: number }>(hub, 'admin_overview')).payments_to_confirm).toBe(1)
    await db.rpc(hub, 'admin_confirm_payment', { p_request_id: id })
    expect(await db.rpc(cliente, 'request_detail', { p_id: id })).toMatchObject({ payment_status: 'paid', payout_status: 'pending' })
    await db.rpc(hub, 'admin_save_pix', { p_pix_key: '', p_pix_holder: '' })
    expect(await db.rpc(cliente, 'payment_info')).toMatchObject({ mode: 'demo' })
  })
})

describe('acesso da equipe da HUB e limite de tentativas', () => {
  it('o código de ativação vale uma vez e só para conta sem cadastro', async () => {
    const codigo = await db.rpc<string>(hub, 'admin_new_setup_code')
    await expect(db.rpc(cliente, 'admin_new_setup_code')).rejects.toMatchObject(denied)
    const [{ id }] = await db.admin<{ id: string }>(`insert into auth.users (email) values ('equipe@teste.invalid') returning id`)
    const novo = { sub: id, role: 'authenticated' as const }
    await expect(db.rpc(novo, 'claim_hub_admin', { p_code: 'ERRADO', p_full_name: 'Nova Pessoa', p_phone: '98911112222' })).rejects.toMatchObject({ message: 'invalid_code' })
    await expect(db.rpc(cliente, 'claim_hub_admin', { p_code: codigo, p_full_name: 'Carla', p_phone: '98911112222' })).rejects.toMatchObject({ message: 'profile_exists' })
    await db.rpc(novo, 'claim_hub_admin', { p_code: codigo.toLowerCase(), p_full_name: 'Nova Pessoa', p_phone: '98911112222' })
    expect(await db.rpc<{ providers: unknown }>(novo, 'admin_overview')).toHaveProperty('providers')
    const [{ id: outroId }] = await db.admin<{ id: string }>(`insert into auth.users (email) values ('intruso@teste.invalid') returning id`)
    await expect(db.rpc({ sub: outroId, role: 'authenticated' }, 'claim_hub_admin', { p_code: codigo, p_full_name: 'Intruso', p_phone: '98911112222' }))
      .rejects.toMatchObject({ message: 'invalid_code' })
  })
  it('o limitador conta tentativas e só o servidor o usa', async () => {
    await expect(db.rpc(cliente, 'check_rate_limit', { p_key: 'k', p_max: 2, p_window_seconds: 60, p_increment: true })).rejects.toMatchObject({ code: '42501' })
    const tentar = () => db.rpc<boolean>(service, 'check_rate_limit', { p_key: 'k', p_max: 2, p_window_seconds: 60, p_increment: true })
    expect([await tentar(), await tentar(), await tentar()]).toEqual([true, true, false])
    expect(await db.rpc(service, 'check_rate_limit', { p_key: 'k', p_max: 2, p_window_seconds: 60, p_increment: false })).toBe(false)
    await db.rpc(service, 'clear_rate_limit', { p_key: 'k' })
    expect(await db.rpc(service, 'check_rate_limit', { p_key: 'k', p_max: 2, p_window_seconds: 60, p_increment: false })).toBe(true)
  })
})
