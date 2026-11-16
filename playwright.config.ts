import { defineConfig, devices } from '@playwright/test'

/**
 * Testes ponta a ponta: usam o emulador local do Supabase (tools/local-stack) e
 * o build de produção (`pnpm build` antes). O banco local é recriado no início.
 */
export default defineConfig({
  testDir: 'tests/e2e',
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  timeout: 120_000,
  expect: { timeout: 15_000 },
  reporter: process.env.CI ? [['github'], ['list']] : [['list']],
  globalSetup: './tests/e2e/global-setup.ts',
  use: {
    baseURL: 'http://localhost:3000',
    locale: 'pt-BR',
    timezoneId: 'America/Fortaleza',
    trace: 'off',
    screenshot: 'only-on-failure',
  },
  projects: [{ name: 'celular', use: { ...devices['Pixel 7'] } }],
  webServer: [
    {
      command: 'pnpm local:api',
      url: 'http://127.0.0.1:54321/health',
      reuseExistingServer: !process.env.CI,
      timeout: 60_000,
      // O emulador do Asaas entrega webhooks e pede a validação de saque ao aplicativo.
      env: { MOCK_ASAAS_WEBHOOK_URL: 'http://localhost:3000/api/webhooks/asaas', MOCK_ASAAS_VALIDATION_URL: 'http://localhost:3000/api/webhooks/asaas/saque' },
    },
    { command: 'pnpm start', url: 'http://localhost:3000/login', reuseExistingServer: !process.env.CI, timeout: 120_000 },
  ],
})
