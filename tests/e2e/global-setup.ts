import { loadDemo } from '../../tools/local-stack/demo'

// Banco local limpo, com as contas fictícias de demonstração.
export default async function setup(): Promise<void> {
  await loadDemo(process.env.LOCAL_DB_NAME ?? 'zedocarro_local')
}
