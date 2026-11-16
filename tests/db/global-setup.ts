import { resetDatabase } from '../../tools/local-stack/db'

export const TEMPLATE_DB = 'zedocarro_test_template'

// Monta uma vez um banco-modelo com todas as migrações; cada arquivo de teste
// trabalha em uma cópia própria (ver harness.ts).
export default async function setup(): Promise<void> {
  await resetDatabase(TEMPLATE_DB)
}
