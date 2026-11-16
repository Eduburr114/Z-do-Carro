/**
 * SOMENTE DESENVOLVIMENTO/TESTE LOCAL — NUNCA USE EM PRODUÇÃO.
 *
 * Emulador mínimo da API do Supabase para rodar o Zé do Carro sem Docker:
 *   /auth/v1/*        subconjunto do Supabase Auth (cadastro, login por senha,
 *                     renovação de sessão, API de administração de usuários)
 *   /rest/v1/rpc/:fn  chamadas RPC, executadas no PostgreSQL local com o papel e
 *                     as claims do JWT, como o PostgREST faz
 *
 * O aplicativo só usa RPC, então isto basta para desenvolver e para os testes
 * ponta a ponta. Em produção (e no CI) o sistema fala com o Supabase de verdade;
 * este arquivo não é carregado pelo aplicativo.
 */
import { generateKeyPairSync, randomBytes, randomUUID, type KeyObject, createPrivateKey, createPublicKey } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { SignJWT, exportJWK, jwtVerify } from 'jose'
import pg from 'pg'
import { databaseUrl } from './db'
import { callRpc, RpcError, type Claims } from './rpc'

export const LOCAL_PUBLISHABLE_KEY = 'sb_publishable_local_somente_desenvolvimento'
export const LOCAL_SECRET_KEY = 'sb_secret_local_somente_desenvolvimento'

const here = dirname(fileURLToPath(import.meta.url))
const stateDir = join(here, '..', '..', '.local-stack')
const ACCESS_TOKEN_SECONDS = 3600

type Keys = { privateKey: KeyObject; publicKey: KeyObject; kid: string }

function loadKeys(): Keys {
  const file = join(stateDir, 'jwt-key.json')
  if (!existsSync(stateDir)) mkdirSync(stateDir, { recursive: true })
  if (!existsSync(file)) {
    const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' })
    writeFileSync(file, JSON.stringify({ kid: randomUUID(), pem: privateKey.export({ type: 'pkcs8', format: 'pem' }) }), { mode: 0o600 })
  }
  const saved = JSON.parse(readFileSync(file, 'utf8')) as { kid: string; pem: string }
  const privateKey = createPrivateKey(saved.pem)
  return { privateKey, publicKey: createPublicKey(privateKey), kid: saved.kid }
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly errorCode: string,
    message: string,
  ) {
    super(message)
  }
}

type UserRow = {
  id: string
  email: string
  email_confirmed_at: string | null
  banned_until: string | null
  raw_user_meta_data: Record<string, unknown>
  last_sign_in_at: string | null
  created_at: string
  updated_at: string
}

export async function startLocalStack(options: { database: string; port: number; quiet?: boolean }) {
  const keys = loadKeys()
  const pool = new pg.Pool({ connectionString: databaseUrl(options.database), max: 10 })
  // Recriar o banco (pnpm local:db) derruba as conexões ociosas; sem este
  // tratamento o emulador cairia. O pool abre conexões novas sozinho.
  pool.on('error', () => undefined)
  const issuer = `http://127.0.0.1:${options.port}/auth/v1`
  const recoveryTokens = new Map<string, { userId: string; expires: number }>()
  const outbox = new Map<string, string>()

  async function userJson(id: string) {
    const { rows } = await pool.query<UserRow>('select * from auth.users where id = $1', [id])
    const user = rows[0]
    if (!user) throw new HttpError(404, 'user_not_found', 'User not found')
    const factors = await pool.query(
      `select id, friendly_name, factor_type, status, created_at, updated_at from auth.mfa_factors where user_id = $1 order by created_at`,
      [id],
    )
    return {
      id: user.id,
      aud: 'authenticated',
      role: 'authenticated',
      email: user.email,
      email_confirmed_at: user.email_confirmed_at,
      confirmed_at: user.email_confirmed_at,
      phone: '',
      last_sign_in_at: user.last_sign_in_at,
      app_metadata: { provider: 'email', providers: ['email'] },
      user_metadata: user.raw_user_meta_data,
      identities: [],
      factors: factors.rows,
      created_at: user.created_at,
      updated_at: user.updated_at,
      is_anonymous: false,
    }
  }

  async function issueSession(sessionId: string) {
    const { rows } = await pool.query<{ user_id: string; aal: string; amr: unknown[] }>(
      'select user_id, aal, amr from auth.sessions where id = $1',
      [sessionId],
    )
    const session = rows[0]
    if (!session) throw new HttpError(403, 'session_not_found', 'Session not found')
    const user = await userJson(session.user_id)
    const now = Math.floor(Date.now() / 1000)
    const accessToken = await new SignJWT({
      email: user.email,
      phone: '',
      app_metadata: user.app_metadata,
      user_metadata: user.user_metadata,
      role: 'authenticated',
      aal: session.aal,
      amr: session.amr,
      session_id: sessionId,
      is_anonymous: false,
    })
      .setProtectedHeader({ alg: 'ES256', kid: keys.kid, typ: 'JWT' })
      .setIssuer(issuer)
      .setSubject(user.id)
      .setAudience('authenticated')
      .setIssuedAt(now)
      .setExpirationTime(now + ACCESS_TOKEN_SECONDS)
      .sign(keys.privateKey)
    const refreshToken = randomBytes(24).toString('base64url')
    await pool.query('update auth.refresh_tokens set revoked = true where session_id = $1', [sessionId])
    await pool.query('insert into auth.refresh_tokens (token, session_id) values ($1, $2)', [refreshToken, sessionId])
    await pool.query('update auth.sessions set refreshed_at = now() where id = $1', [sessionId])
    return {
      access_token: accessToken,
      token_type: 'bearer',
      expires_in: ACCESS_TOKEN_SECONDS,
      expires_at: now + ACCESS_TOKEN_SECONDS,
      refresh_token: refreshToken,
      user,
    }
  }

  async function verifyBearer(token: string) {
    try {
      const { payload } = await jwtVerify(token, keys.publicKey, { issuer, audience: 'authenticated' })
      return payload as { sub: string; session_id: string; aal: string } & Record<string, unknown>
    } catch {
      throw new HttpError(401, 'bad_jwt', 'Invalid or expired JWT')
    }
  }

  function bearer(req: IncomingMessage): string | null {
    const header = req.headers.authorization
    return header?.startsWith('Bearer ') ? header.slice(7) : null
  }

  async function requireSession(req: IncomingMessage) {
    const token = bearer(req)
    if (!token) throw new HttpError(401, 'no_authorization', 'Missing authorization header')
    const payload = await verifyBearer(token)
    const { rows } = await pool.query('select 1 from auth.sessions where id = $1', [payload.session_id])
    if (rows.length === 0) throw new HttpError(403, 'session_not_found', 'Session from session_id claim in JWT does not exist')
    return payload
  }

  function requireService(req: IncomingMessage): void {
    if (bearer(req) !== LOCAL_SECRET_KEY) throw new HttpError(401, 'not_admin', 'User not allowed')
  }

  function assertPassword(password: unknown): asserts password is string {
    if (typeof password !== 'string' || password.length < 8) {
      throw new HttpError(422, 'weak_password', 'Password should be at least 8 characters')
    }
  }

  async function handleAuth(req: IncomingMessage, url: URL, body: Record<string, unknown>): Promise<unknown> {
    const path = url.pathname.replace(/^\/auth\/v1/, '')
    const method = req.method ?? 'GET'

    if (path === '/.well-known/jwks.json' && method === 'GET') {
      const jwk = await exportJWK(keys.publicKey)
      return { keys: [{ ...jwk, kid: keys.kid, alg: 'ES256', use: 'sig', key_ops: ['verify'] }] }
    }

    // Cadastro aberto (cliente ou prestador). Sem confirmação de e-mail no emulador.
    if (path === '/signup' && method === 'POST') {
      assertPassword(body.password)
      const email = String(body.email ?? '').toLowerCase()
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new HttpError(422, 'validation_failed', 'Invalid email')
      const exists = await pool.query('select 1 from auth.users where email = $1', [email])
      if (exists.rows.length > 0) throw new HttpError(422, 'user_already_exists', 'User already registered')
      const created = await pool.query<{ id: string }>(
        `insert into auth.users (email, encrypted_password, raw_user_meta_data)
         values ($1, extensions.crypt($2, extensions.gen_salt('bf')), $3::jsonb) returning id`,
        [email, body.password, JSON.stringify(body.data ?? {})],
      )
      const session = await pool.query<{ id: string }>(
        `insert into auth.sessions (user_id, aal, amr) values ($1, 'aal1', $2::jsonb) returning id`,
        [created.rows[0].id, JSON.stringify([{ method: 'password', timestamp: Math.floor(Date.now() / 1000) }])],
      )
      return issueSession(session.rows[0].id)
    }

    // Recuperação de senha. O emulador não envia e-mail: guarda o link em
    // memória e o mostra no console e em GET /auth/v1/local/outbox (para testes).
    if (path === '/recover' && method === 'POST') {
      const email = String(body.email ?? '').toLowerCase()
      const { rows } = await pool.query<{ id: string }>('select id from auth.users where email = $1', [email])
      if (rows.length > 0) {
        const tokenHash = randomBytes(24).toString('hex')
        recoveryTokens.set(tokenHash, { userId: rows[0].id, expires: Date.now() + 60 * 60 * 1000 })
        const site = (url.searchParams.get('redirect_to') ?? 'http://localhost:3000').replace(/\/$/, '')
        const link = `${new URL(site).origin}/auth/confirmar?token_hash=${tokenHash}&type=recovery`
        outbox.set(email, link)
        if (!options.quiet) console.log(`[e-mail local] recuperação de senha para ${email}: ${link}`)
      }
      return {} // mesma resposta para e-mail existente ou não
    }
    if (path === '/local/outbox' && method === 'GET') {
      return { link: outbox.get(String(url.searchParams.get('email') ?? '').toLowerCase()) ?? null }
    }
    if (path === '/verify' && method === 'POST') {
      const entry = recoveryTokens.get(String(body.token_hash ?? ''))
      if (!entry || entry.expires < Date.now() || body.type !== 'recovery') {
        throw new HttpError(403, 'otp_expired', 'Email link is invalid or has expired')
      }
      recoveryTokens.delete(String(body.token_hash))
      const session = await pool.query<{ id: string }>(
        `insert into auth.sessions (user_id, aal, amr) values ($1, 'aal1', $2::jsonb) returning id`,
        [entry.userId, JSON.stringify([{ method: 'recovery', timestamp: Math.floor(Date.now() / 1000) }])],
      )
      return issueSession(session.rows[0].id)
    }

    if (path === '/token' && method === 'POST') {
      const grant = url.searchParams.get('grant_type')
      if (grant === 'password') {
        const { rows } = await pool.query<{ id: string; banned_until: string | null }>(
          `select id, banned_until from auth.users
           where email = lower($1) and encrypted_password = extensions.crypt($2, encrypted_password)`,
          [String(body.email ?? ''), String(body.password ?? '')],
        )
        if (rows.length === 0) throw new HttpError(400, 'invalid_credentials', 'Invalid login credentials')
        if (rows[0].banned_until && new Date(rows[0].banned_until) > new Date()) {
          throw new HttpError(400, 'user_banned', 'User is banned')
        }
        const session = await pool.query<{ id: string }>(
          `insert into auth.sessions (user_id, aal, amr) values ($1, 'aal1', $2::jsonb) returning id`,
          [rows[0].id, JSON.stringify([{ method: 'password', timestamp: Math.floor(Date.now() / 1000) }])],
        )
        await pool.query('update auth.users set last_sign_in_at = now() where id = $1', [rows[0].id])
        return issueSession(session.rows[0].id)
      }
      if (grant === 'refresh_token') {
        const { rows } = await pool.query<{ session_id: string; revoked: boolean; user_id: string; banned_until: string | null }>(
          `select t.session_id, t.revoked, s.user_id, u.banned_until
           from auth.refresh_tokens t join auth.sessions s on s.id = t.session_id join auth.users u on u.id = s.user_id
           where t.token = $1`,
          [String(body.refresh_token ?? '')],
        )
        if (rows.length === 0) throw new HttpError(400, 'refresh_token_not_found', 'Invalid Refresh Token: Refresh Token Not Found')
        if (rows[0].revoked) throw new HttpError(400, 'refresh_token_already_used', 'Invalid Refresh Token: Already Used')
        if (rows[0].banned_until && new Date(rows[0].banned_until) > new Date()) throw new HttpError(400, 'user_banned', 'User is banned')
        return issueSession(rows[0].session_id)
      }
      throw new HttpError(400, 'unsupported_grant_type', 'Unsupported grant type')
    }

    if (path === '/user' && method === 'GET') {
      const payload = await requireSession(req)
      return userJson(payload.sub)
    }

    if (path === '/user' && method === 'PUT') {
      const payload = await requireSession(req)
      if (body.password !== undefined) {
        assertPassword(body.password)
        await pool.query(
          `update auth.users set encrypted_password = extensions.crypt($2, extensions.gen_salt('bf')), updated_at = now() where id = $1`,
          [payload.sub, body.password],
        )
      }
      return userJson(payload.sub)
    }

    if (path === '/logout' && method === 'POST') {
      const payload = await requireSession(req)
      const scope = url.searchParams.get('scope') ?? 'global'
      if (scope === 'local') await pool.query('delete from auth.sessions where id = $1', [payload.session_id])
      else if (scope === 'others') await pool.query('delete from auth.sessions where user_id = $1 and id <> $2', [payload.sub, payload.session_id])
      else await pool.query('delete from auth.sessions where user_id = $1', [payload.sub])
      return null
    }

    // ----- Administração (chave secreta) -----
    if (path === '/admin/users' && method === 'POST') {
      requireService(req)
      assertPassword(body.password)
      const email = String(body.email ?? '').toLowerCase()
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new HttpError(422, 'validation_failed', 'Invalid email')
      const exists = await pool.query('select 1 from auth.users where email = $1', [email])
      if (exists.rows.length > 0) throw new HttpError(422, 'email_exists', 'A user with this email address has already been registered')
      const { rows } = await pool.query<{ id: string }>(
        `insert into auth.users (email, encrypted_password, raw_user_meta_data)
         values ($1, extensions.crypt($2, extensions.gen_salt('bf')), $3::jsonb) returning id`,
        [email, body.password, JSON.stringify(body.user_metadata ?? {})],
      )
      return userJson(rows[0].id)
    }

    const adminUser = path.match(/^\/admin\/users\/([0-9a-f-]{36})(\/factors(?:\/([0-9a-f-]{36}))?)?$/)
    if (adminUser) {
      requireService(req)
      const userId = adminUser[1]
      if (!adminUser[2] && method === 'GET') return userJson(userId)
      if (!adminUser[2] && method === 'DELETE') {
        // Só usuários sem perfil (a exclusão é recusada pela chave estrangeira caso contrário).
        await pool.query('delete from auth.users where id = $1', [userId])
        return {}
      }
      if (!adminUser[2] && method === 'PUT') {
        if (body.password !== undefined) {
          assertPassword(body.password)
          await pool.query(
            `update auth.users set encrypted_password = extensions.crypt($2, extensions.gen_salt('bf')), updated_at = now() where id = $1`,
            [userId, body.password],
          )
        }
        if (typeof body.ban_duration === 'string') {
          if (body.ban_duration === 'none') {
            await pool.query('update auth.users set banned_until = null where id = $1', [userId])
          } else {
            await pool.query(`update auth.users set banned_until = now() + interval '100 years' where id = $1`, [userId])
            await pool.query('delete from auth.sessions where user_id = $1', [userId])
          }
        }
        return userJson(userId)
      }
      if (adminUser[2] && !adminUser[3] && method === 'GET') return (await userJson(userId)).factors
      if (adminUser[3] && method === 'DELETE') {
        await pool.query('delete from auth.mfa_factors where id = $1 and user_id = $2', [adminUser[3], userId])
        await pool.query('delete from auth.sessions where user_id = $1', [userId])
        return { id: adminUser[3] }
      }
    }

    throw new HttpError(404, 'not_found', `Rota de auth não emulada: ${method} ${path}`)
  }

  async function handleRpc(req: IncomingMessage, url: URL, body: Record<string, unknown>): Promise<unknown> {
    const name = url.pathname.replace(/^\/rest\/v1\/rpc\//, '')
    const token = bearer(req)
    let claims: Claims
    if (token === LOCAL_SECRET_KEY) {
      claims = { role: 'service_role' }
    } else if (!token || token === LOCAL_PUBLISHABLE_KEY) {
      claims = { role: 'anon' }
    } else {
      const payload = await verifyBearer(token)
      claims = { ...payload, role: 'authenticated', aal: payload.aal as 'aal1' | 'aal2' }
    }
    const client = await pool.connect()
    try {
      return await callRpc(client, claims, name, body)
    } finally {
      client.release()
    }
  }

  async function readBody(req: IncomingMessage): Promise<Record<string, unknown>> {
    const chunks: Buffer[] = []
    let size = 0
    for await (const chunk of req) {
      size += (chunk as Buffer).length
      if (size > 1_000_000) throw new HttpError(413, 'payload_too_large', 'Payload too large')
      chunks.push(chunk as Buffer)
    }
    if (chunks.length === 0) return {}
    try {
      return JSON.parse(Buffer.concat(chunks).toString('utf8')) as Record<string, unknown>
    } catch {
      throw new HttpError(400, 'bad_json', 'Could not parse request body as JSON')
    }
  }

  function send(res: ServerResponse, status: number, payload: unknown): void {
    const text = payload === null || payload === undefined ? '' : JSON.stringify(payload)
    res.writeHead(status, {
      'content-type': 'application/json; charset=utf-8',
      'access-control-allow-origin': '*',
      'access-control-allow-headers': '*',
      'access-control-allow-methods': 'GET,POST,PUT,DELETE,OPTIONS',
    })
    res.end(text)
  }

  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? '/', `http://127.0.0.1:${options.port}`)
    try {
      if (req.method === 'OPTIONS') return send(res, 204, null)
      const apikey = req.headers.apikey
      if (url.pathname !== '/health' && apikey !== LOCAL_PUBLISHABLE_KEY && apikey !== LOCAL_SECRET_KEY) {
        throw new HttpError(401, 'no_api_key', 'No API key found in request')
      }
      const body = ['POST', 'PUT', 'PATCH'].includes(req.method ?? '') ? await readBody(req) : {}
      if (url.pathname === '/health') return send(res, 200, { ok: true })
      if (url.pathname.startsWith('/auth/v1/')) {
        const result = await handleAuth(req, url, body)
        return send(res, result === null ? 204 : 200, result)
      }
      if (url.pathname.startsWith('/rest/v1/rpc/') && req.method === 'POST') {
        const result = await handleRpc(req, url, body)
        return send(res, result === null ? 204 : 200, result)
      }
      throw new HttpError(404, 'not_found', `Rota não emulada: ${req.method} ${url.pathname} (o aplicativo usa somente RPC)`)
    } catch (error) {
      if (error instanceof HttpError) {
        return send(res, error.status, { code: error.status, error_code: error.errorCode, msg: error.message, message: error.message })
      }
      if (error instanceof RpcError) {
        const status = error.code === '42501' ? 403 : error.code.startsWith('PGRST') ? 404 : 400
        return send(res, status, { code: error.code, message: error.message, details: error.details, hint: error.hint })
      }
      if (!options.quiet) console.error(error)
      return send(res, 500, { code: 'XX000', message: 'internal error' })
    }
  })

  await new Promise<void>((resolve) => server.listen(options.port, '127.0.0.1', resolve))
  if (!options.quiet) console.log(`Emulador local do Supabase em http://127.0.0.1:${options.port} (banco ${options.database})`)

  return {
    url: `http://127.0.0.1:${options.port}`,
    async close() {
      await new Promise((resolve) => server.close(resolve))
      await pool.end()
    },
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  startLocalStack({
    database: process.env.LOCAL_DB_NAME ?? 'zedocarro_local',
    port: Number(process.env.LOCAL_API_PORT ?? 54321),
  }).catch((error) => {
    console.error(error)
    process.exit(1)
  })
}
