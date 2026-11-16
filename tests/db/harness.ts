/**
 * Apoio aos testes de banco. Cada arquivo de teste recebe uma cópia limpa do
 * banco-modelo. As chamadas são feitas como a API faria: papel `authenticated`
 * (ou `anon`) e claims do JWT definidas por transação — nunca como superusuário,
 * exceto para preparar o cenário (`admin`).
 */
import { randomUUID } from 'node:crypto'
import pg from 'pg'
import { ADMIN_URL, databaseUrl } from '../../tools/local-stack/db'
import { callRpc, withClaims, type Claims } from '../../tools/local-stack/rpc'
import { TEMPLATE_DB } from './global-setup'

export type TestUser = Claims & { sub: string; name: string }

export class TestDb {
  private constructor(
    readonly name: string,
    readonly pool: pg.Pool,
  ) {}

  static async create(): Promise<TestDb> {
    const name = `zedocarro_t_${randomUUID().replace(/-/g, '').slice(0, 12)}`
    const admin = new pg.Client({ connectionString: ADMIN_URL })
    await admin.connect()
    try {
      await admin.query(`create database ${name} template ${TEMPLATE_DB}`)
    } finally {
      await admin.end()
    }
    const pool = new pg.Pool({ connectionString: databaseUrl(name), max: 8 })
    return new TestDb(name, pool)
  }

  async destroy(): Promise<void> {
    await this.pool.end()
    const admin = new pg.Client({ connectionString: ADMIN_URL })
    await admin.connect()
    try {
      await admin.query(`drop database if exists ${this.name} with (force)`)
    } finally {
      await admin.end()
    }
  }

  /** Superusuário: só para preparar e inspecionar o cenário. */
  async admin<T extends pg.QueryResultRow = pg.QueryResultRow>(sql: string, params: unknown[] = []): Promise<T[]> {
    const { rows } = await this.pool.query<T>(sql, params)
    return rows
  }

  /** Cria a conta e, pelas vias normais, o cadastro de cliente ou prestador. */
  async createUser(role: 'customer' | 'provider' | 'hub_admin', name = `Teste ${role}`): Promise<TestUser> {
    const id = randomUUID()
    const email = `${role}.${id.slice(0, 8)}@teste.invalid`
    await this.admin('insert into auth.users (id, email) values ($1, $2)', [id, email])
    const user: TestUser = { sub: id, role: 'authenticated', aal: 'aal1', name }
    if (role === 'hub_admin') {
      await this.rpc(service, 'promote_hub_admin', { p_email: email, p_full_name: name, p_phone: '98999990000' })
    } else {
      await this.rpc(user, 'register_profile', { p_full_name: name, p_phone: '(98) 99999-0000', p_role: role, p_terms_version: 'teste' })
    }
    return user
  }

  /** Chama uma RPC como o usuário (ou como anônimo / serviço). */
  async rpc<T = unknown>(user: Claims, name: string, args: Record<string, unknown> = {}): Promise<T> {
    const client = await this.pool.connect()
    try {
      return (await callRpc(client, user, name, args)) as T
    } finally {
      client.release()
    }
  }

  /** Executa SQL direto com o papel e as claims do usuário (simula acesso direto à API de tabelas). */
  async query<T extends pg.QueryResultRow = pg.QueryResultRow>(user: Claims, sql: string, params: unknown[] = []): Promise<T[]> {
    const client = await this.pool.connect()
    try {
      return await withClaims(client, user, async () => (await client.query<T>(sql, params)).rows)
    } finally {
      client.release()
    }
  }
}

/** PNG de 1 pixel, em base64, para os testes de documentos. */
export const PNG_1PX = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='

export const anon: Claims = { role: 'anon' }
export const service: Claims = { role: 'service_role' }

/** CPF fictício com dígitos verificadores válidos (só para testes). */
export const CPF_TESTE = '52998224725'

let fakeExternal = 0
/**
 * Simula o caminho oficial de um Pix: o cliente pede a cobrança, o servidor
 * registra a cobrança criada no provedor e, depois, o estado RECEIVED vindo da
 * API do provedor (o que o webhook dispara). Nada disso o cliente consegue
 * fazer sozinho.
 */
export async function pagarPix(db: TestDb, cliente: TestUser, requestId: string, extraId: string | null = null, opts: { value?: number } = {}) {
  await db.rpc(cliente, 'save_payment_tax_id', { p_tax_id: CPF_TESTE })
  const start = await db.rpc<{ action: string; payment_id: string; amount_cents: number; attempt_key: string }>(cliente, 'payment_start', {
    p_request_id: requestId, p_extra_id: extraId,
  })
  const externalId = `pay_teste_${++fakeExternal}`
  if (start.action === 'create') {
    await db.rpc(service, 'payment_charge_created', {
      p_payment_id: start.payment_id, p_external_id: externalId, p_status: 'PENDING',
      p_pix_payload: '00020126pix-copia-e-cola-ficticio', p_pix_qr_image: 'iVBORw0KGgo=', p_pix_expires_at: new Date(Date.now() + 3600_000).toISOString(),
    })
  }
  const [{ amount_cents, external_id }] = await db.admin<{ amount_cents: string; external_id: string }>(
    'select amount_cents, external_id from public.payments where id = $1', [start.payment_id])
  const value = opts.value ?? Number(amount_cents)
  const result = await db.rpc<{ result: string }>(service, 'payment_sync', {
    p_external_id: external_id, p_external_reference: start.attempt_key ?? null, p_status: 'RECEIVED',
    p_value_cents: value, p_net_cents: value - 99, p_deleted: false,
  })
  return { paymentId: start.payment_id, externalId: external_id, result: result.result }
}
