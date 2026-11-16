import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { expect, it } from 'vitest'

it('supabase/instalar.sql está em dia com as migrações', () => {
  const before = readFileSync('supabase/instalar.sql', 'utf8')
  execFileSync('bash', ['scripts/gerar-instalacao.sh'])
  expect(readFileSync('supabase/instalar.sql', 'utf8'), 'rode ./scripts/gerar-instalacao.sh e inclua o arquivo no commit').toBe(before)
})
