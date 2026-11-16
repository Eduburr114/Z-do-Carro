/**
 * SOMENTE DESENVOLVIMENTO LOCAL. Recria o banco local e carrega contas FICTÍCIAS
 * de demonstração, uma por papel, usando as mesmas funções que o aplicativo usa.
 * Nada aqui é dado real.
 */
import { fileURLToPath } from 'node:url'
import pg from 'pg'
import { resetDatabase } from './db'
import { callRpc, type Claims } from './rpc'

export const DEMO_PASSWORD = 'demonstracao-local-2026'
export const DEMO_USERS = {
  hub: { email: 'hub@demo.invalid', name: 'Equipe HUB (demo)' },
  cliente: { email: 'cliente@demo.invalid', name: 'Carla Cliente (demo)' },
  ze: { email: 'ze@demo.invalid', name: 'Zé Borracheiro (demo)' },
  novato: { email: 'novato@demo.invalid', name: 'Nino Novato (demo)' },
} as const

const SAO_LUIS = { lat: -2.5307, lng: -44.3068 }

export async function loadDemo(database: string): Promise<void> {
  const url = await resetDatabase(database)
  const client = new pg.Client({ connectionString: url })
  await client.connect()
  try {
    const claims = {} as Record<keyof typeof DEMO_USERS, Claims>
    for (const [key, user] of Object.entries(DEMO_USERS) as [keyof typeof DEMO_USERS, { email: string }][]) {
      const { rows } = await client.query<{ id: string }>(
        `insert into auth.users (email, encrypted_password) values ($1, extensions.crypt($2, extensions.gen_salt('bf'))) returning id`,
        [user.email, DEMO_PASSWORD],
      )
      claims[key] = { sub: rows[0].id, role: 'authenticated', aal: 'aal1' }
    }
    const call = <T = unknown>(who: keyof typeof DEMO_USERS, fn: string, args: Record<string, unknown> = {}) =>
      callRpc(client, claims[who], fn, args) as Promise<T>

    await callRpc(client, { role: 'service_role' }, 'promote_hub_admin', { p_email: DEMO_USERS.hub.email, p_full_name: DEMO_USERS.hub.name, p_phone: '98900000001' })
    await call('cliente', 'register_profile', { p_full_name: DEMO_USERS.cliente.name, p_phone: '98900000002', p_role: 'customer' })
    await call('ze', 'register_profile', { p_full_name: DEMO_USERS.ze.name, p_phone: '98900000003', p_role: 'provider' })
    await call('novato', 'register_profile', { p_full_name: DEMO_USERS.novato.name, p_phone: '98900000004', p_role: 'provider' })

    await call('cliente', 'save_vehicle', { p_plate: 'DEM0A00', p_brand: 'Fiat', p_model: 'Argo', p_year: 2021 })
    const services = await call<{ id: string }[]>('cliente', 'list_services')
    const all = services.map((s) => s.id)

    // Zé: credenciado em tudo e com o contrato aceito. Nino: aguardando análise.
    const apply = (who: 'ze' | 'novato', ids: string[]) =>
      call(who, 'provider_apply', {
        p_doc_type: 'cpf', p_doc_number: who === 'ze' ? '00000000191' : '00000000272', p_legal_name: DEMO_USERS[who].name,
        p_city: 'São Luís', p_experience: 'Atendimento móvel com equipamento próprio (dados fictícios).',
        p_radius_km: 25, p_service_ids: ids, p_lat: SAO_LUIS.lat, p_lng: SAO_LUIS.lng,
      })
    await apply('ze', all)
    await call('hub', 'admin_decide_provider', { p_id: claims.ze.sub, p_approved_service_ids: all })
    const contract = await call<{ id: string }>('ze', 'current_contract')
    await call('ze', 'accept_contract', { p_version_id: contract.id, p_ip: '127.0.0.1', p_user_agent: 'demonstração local' })
    await apply('novato', all.slice(0, 2))
  } finally {
    await client.end()
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  loadDemo(process.env.LOCAL_DB_NAME ?? 'zedocarro_local')
    .then(() => {
      console.log('Banco local pronto com contas de demonstração (senha: %s):', DEMO_PASSWORD)
      for (const user of Object.values(DEMO_USERS)) console.log('  %s  %s', user.email.padEnd(24), user.name)
    })
    .catch((error) => {
      console.error(error.message)
      process.exit(1)
    })
}
