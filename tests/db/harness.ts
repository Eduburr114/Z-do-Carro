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
      await this.rpc(user, 'register_profile', { p_full_name: name, p_phone: '(98) 99999-0000', p_role: role })
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

export const anon: Claims = { role: 'anon' }
export const service: Claims = { role: 'service_role' }
