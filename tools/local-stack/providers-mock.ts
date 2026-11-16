/**
 * SOMENTE DESENVOLVIMENTO/TESTE LOCAL — NUNCA USE EM PRODUÇÃO.
 *
 * Emuladores mínimos do Asaas (API v3) e do Resend, para exercitar ponta a ponta
 * cobrança Pix, webhook, estorno, transferência (com validação de saque) e
 * e-mail, sem credencial nem dinheiro real. Imita apenas o que o aplicativo usa,
 * com os mesmos nomes de campos da documentação oficial; NÃO é referência do
 * comportamento real (confira sempre no sandbox do Asaas).
 *
 *   /asaas/v3/...            customers, payments, pixQrCode, refund, transfers, finance/balance
 *   POST /asaas/local/pay/:id   simula o pagamento do Pix (envia PAYMENT_RECEIVED)
 *   GET  /asaas/local/state     estado do emulador
 *   POST /resend/emails      envio (Idempotency-Key respeitada)
 *   GET  /resend/local/outbox   e-mails "enviados"
 */
import { randomUUID } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'

export const LOCAL_ASAAS_API_KEY = 'asaas_local_somente_desenvolvimento'
export const LOCAL_ASAAS_WEBHOOK_TOKEN = 'webhook-local-somente-desenvolvimento-0123456789'
export const LOCAL_ASAAS_VALIDATION_TOKEN = 'validacao-local-somente-desenvolvimento-0123456789'
export const LOCAL_RESEND_API_KEY = 're_local_somente_desenvolvimento'

type Payment = { id: string; customer: string; value: number; netValue: number; status: string; externalReference: string | null; deleted: boolean; dueDate: string; billingType: string; description: string }
type Transfer = { id: string; value: number; status: string; externalReference: string | null; pixAddressKey: string; pixAddressKeyType: string; failReason: string | null; transferFee: number; description: string }
type Email = { id: string; to: string[]; subject: string; html: string; text: string; idempotencyKey: string | null; tags: unknown }

export type ProvidersMockOptions = {
  /** Para onde vão os webhooks (URL) ou função chamada no lugar (testes). */
  webhook?: string | ((body: Record<string, unknown>) => Promise<void>)
  /** URL ou função do mecanismo de validação de saque; sem isto, aprova. */
  transferValidation?: string | ((body: Record<string, unknown>) => Promise<{ status: string; refuseReason?: string }>)
  /** Tarifa fictícia por cobrança Pix recebida. */
  pixFee?: number
  quiet?: boolean
}

export function createProvidersMock(options: ProvidersMockOptions = {}) {
  const customers = new Map<string, Record<string, unknown>>()
  const payments = new Map<string, Payment>()
  const transfers = new Map<string, Transfer>()
  const emails: Email[] = []
  const idempotency = new Map<string, string>()
  let balance = 0
  /** Falhas programadas pelos testes: rota → status a devolver (uma vez). */
  const failNext = new Map<string, number>()
  const pending: Promise<unknown>[] = []

  const log = (...args: unknown[]) => {
    if (!options.quiet) console.log('[emulador provedores]', ...args)
  }

  async function sendWebhook(body: Record<string, unknown>) {
    const target = options.webhook ?? process.env.MOCK_ASAAS_WEBHOOK_URL ?? 'http://localhost:3000/api/webhooks/asaas'
    try {
      if (typeof target === 'function') return await target(body)
      await fetch(target, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'asaas-access-token': LOCAL_ASAAS_WEBHOOK_TOKEN },
        body: JSON.stringify(body),
      })
    } catch (error) {
      log('webhook não entregue', (error as Error).message)
    }
  }
  const event = (name: string, resource: { payment?: Payment; transfer?: Transfer }) => {
    const body = { id: `evt_${randomUUID()}`, event: name, dateCreated: new Date().toISOString(), ...resource }
    const job = sendWebhook(body as Record<string, unknown>)
    pending.push(job)
    return job
  }

  async function validate(transfer: Transfer): Promise<boolean> {
    const target = options.transferValidation ?? process.env.MOCK_ASAAS_VALIDATION_URL
    if (!target) return true
    const body = { type: 'TRANSFER', transfer: { ...transfer, bankAccount: { pixAddressKey: transfer.pixAddressKey } } }
    try {
      const answer = typeof target === 'function'
        ? await target(body)
        : await (await fetch(target, {
            method: 'POST',
            headers: { 'content-type': 'application/json', 'asaas-access-token': LOCAL_ASAAS_VALIDATION_TOKEN },
            body: JSON.stringify(body),
          })).json() as { status: string }
      return answer.status === 'APPROVED'
    } catch {
      return false
    }
  }

  async function settleTransfer(transfer: Transfer) {
    const approved = await validate(transfer)
    if (!approved) {
      transfer.status = 'CANCELLED'
      transfer.failReason = 'Recusada pelo mecanismo de validação de saque'
      await event('TRANSFER_CANCELLED', { transfer })
      return
    }
    if (transfer.pixAddressKey.includes('falha')) {
      transfer.status = 'FAILED'
      transfer.failReason = 'Chave Pix não encontrada'
      await event('TRANSFER_FAILED', { transfer })
      return
    }
    transfer.status = 'DONE'
    balance -= transfer.value
    await event('TRANSFER_DONE', { transfer })
  }

  function pay(id: string): Payment | null {
    const payment = payments.get(id)
    if (!payment || payment.deleted) return null
    if (payment.status === 'RECEIVED') return payment
    payment.status = 'RECEIVED'
    payment.netValue = Math.round((payment.value - (options.pixFee ?? 0.99)) * 100) / 100
    balance += payment.netValue
    void event('PAYMENT_RECEIVED', { payment })
    return payment
  }

  async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
    const chunks: Buffer[] = []
    for await (const chunk of req) chunks.push(chunk as Buffer)
    if (chunks.length === 0) return {}
    try {
      return JSON.parse(Buffer.concat(chunks).toString('utf8')) as Record<string, unknown>
    } catch {
      return {}
    }
  }
  function send(res: ServerResponse, status: number, body: unknown) {
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' })
    res.end(body === undefined ? '' : JSON.stringify(body))
  }
  const asaasError = (res: ServerResponse, status: number, description: string) =>
    send(res, status, { errors: [{ code: 'invalid_action', description }] })

  async function handleAsaas(req: IncomingMessage, res: ServerResponse, url: URL) {
    const path = url.pathname.replace(/^\/asaas\/v3/, '')
    const method = req.method ?? 'GET'
    if (req.headers.access_token !== LOCAL_ASAAS_API_KEY) return asaasError(res, 401, 'access_token inválido')
    const forced = failNext.get(`${method} ${path.replace(/\/[^/]+_[^/]+/g, '/:id')}`)
    if (forced) {
      failNext.delete(`${method} ${path.replace(/\/[^/]+_[^/]+/g, '/:id')}`)
      if (forced === -1) {
        req.socket.destroy()
        return
      }
      return asaasError(res, forced, 'Falha simulada')
    }
    const body = method === 'GET' ? {} : await readJson(req)

    if (path === '/customers' && method === 'POST') {
      if (!body.name || !body.cpfCnpj) return asaasError(res, 400, 'Nome e CPF/CNPJ são obrigatórios')
      const id = `cus_${randomUUID().slice(0, 12)}`
      customers.set(id, { id, ...body })
      return send(res, 200, customers.get(id))
    }
    if (path === '/payments' && method === 'POST') {
      if (!customers.has(String(body.customer))) return asaasError(res, 400, 'Cliente inexistente')
      if (body.billingType !== 'PIX') return asaasError(res, 400, 'Somente Pix no emulador')
      const payment: Payment = {
        id: `pay_${randomUUID().slice(0, 12)}`, customer: String(body.customer), value: Number(body.value), netValue: Number(body.value),
        status: 'PENDING', externalReference: (body.externalReference as string) ?? null, deleted: false,
        dueDate: String(body.dueDate), billingType: 'PIX', description: String(body.description ?? ''),
      }
      payments.set(payment.id, payment)
      void event('PAYMENT_CREATED', { payment })
      return send(res, 200, payment)
    }
    if (path === '/payments' && method === 'GET') {
      const ref = url.searchParams.get('externalReference')
      const data = [...payments.values()].filter((p) => !ref || p.externalReference === ref)
      return send(res, 200, { object: 'list', hasMore: false, totalCount: data.length, data })
    }
    const qr = /^\/payments\/([^/]+)\/pixQrCode$/.exec(path)
    if (qr && method === 'GET') {
      const payment = payments.get(qr[1])
      if (!payment) return asaasError(res, 404, 'Cobrança não encontrada')
      // Payload fictício que carrega o id, para os testes simularem o pagamento.
      return send(res, 200, {
        encodedImage: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
        payload: `00020126580014br.gov.bcb.pix0136EMULADOR-LOCAL-${payment.id}5204000053039865802BR`,
        expirationDate: new Date(Date.now() + 3600_000).toISOString().slice(0, 19).replace('T', ' '),
      })
    }
    const refund = /^\/payments\/([^/]+)\/refund$/.exec(path)
    if (refund && method === 'POST') {
      const payment = payments.get(refund[1])
      if (!payment) return asaasError(res, 404, 'Cobrança não encontrada')
      if (payment.status !== 'RECEIVED') return asaasError(res, 400, 'Só é possível estornar cobrança recebida')
      payment.status = 'REFUNDED'
      balance -= payment.value
      void event('PAYMENT_REFUNDED', { payment })
      return send(res, 200, payment)
    }
    const one = /^\/payments\/([^/]+)$/.exec(path)
    if (one && method === 'GET') {
      const payment = payments.get(one[1])
      return payment ? send(res, 200, payment) : asaasError(res, 404, 'Cobrança não encontrada')
    }
    if (one && method === 'DELETE') {
      const payment = payments.get(one[1])
      if (!payment) return asaasError(res, 404, 'Cobrança não encontrada')
      if (payment.status === 'RECEIVED') return asaasError(res, 400, 'Cobrança recebida não pode ser removida')
      payment.deleted = true
      void event('PAYMENT_DELETED', { payment })
      return send(res, 200, { deleted: true, id: payment.id })
    }
    if (path === '/transfers' && method === 'POST') {
      if (!body.pixAddressKey || !body.pixAddressKeyType) return asaasError(res, 400, 'Informe a chave Pix')
      const transfer: Transfer = {
        id: `tra_${randomUUID().slice(0, 12)}`, value: Number(body.value), status: 'PENDING',
        externalReference: (body.externalReference as string) ?? null, pixAddressKey: String(body.pixAddressKey),
        pixAddressKeyType: String(body.pixAddressKeyType), failReason: null, transferFee: 0, description: String(body.description ?? ''),
      }
      transfers.set(transfer.id, transfer)
      const job = new Promise((resolve) => setTimeout(resolve, 50)).then(() => settleTransfer(transfer))
      pending.push(job)
      return send(res, 200, transfer)
    }
    const transfer = /^\/transfers\/([^/]+)$/.exec(path)
    if (transfer && method === 'GET') {
      const t = transfers.get(transfer[1])
      return t ? send(res, 200, t) : asaasError(res, 404, 'Transferência não encontrada')
    }
    if (path === '/finance/balance' && method === 'GET') return send(res, 200, { balance: Math.round(balance * 100) / 100 })
    return asaasError(res, 404, `Rota não emulada: ${method} ${path}`)
  }

  async function handleResend(req: IncomingMessage, res: ServerResponse, url: URL) {
    if (url.pathname === '/resend/local/outbox' && req.method === 'GET') {
      const to = url.searchParams.get('to')
      return send(res, 200, emails.filter((e) => !to || e.to.includes(to)))
    }
    if (url.pathname === '/resend/emails' && req.method === 'POST') {
      if (req.headers.authorization !== `Bearer ${LOCAL_RESEND_API_KEY}`) return send(res, 401, { name: 'validation_error', message: 'API key is invalid' })
      const key = (req.headers['idempotency-key'] as string | undefined) ?? null
      if (key && idempotency.has(key)) return send(res, 200, { id: idempotency.get(key) })
      const body = await readJson(req)
      const to = (body.to as string[]) ?? []
      if (to.some((t) => t.includes('+falha-temporaria'))) return send(res, 429, { name: 'rate_limit_exceeded', message: 'Too many requests' })
      if (to.some((t) => t.includes('+falha'))) return send(res, 422, { name: 'validation_error', message: 'Invalid `to` field' })
      const email: Email = { id: randomUUID(), to, subject: String(body.subject), html: String(body.html), text: String(body.text), idempotencyKey: key, tags: body.tags }
      emails.push(email)
      if (key) idempotency.set(key, email.id)
      return send(res, 200, { id: email.id })
    }
    return send(res, 404, { message: 'Rota não emulada' })
  }

  return {
    /** Trata a requisição se for de um dos emuladores; devolve false caso contrário. */
    async handle(req: IncomingMessage, res: ServerResponse): Promise<boolean> {
      const url = new URL(req.url ?? '/', 'http://127.0.0.1')
      if (url.pathname.startsWith('/asaas/v3/')) {
        await handleAsaas(req, res, url)
        return true
      }
      const payRoute = /^\/asaas\/local\/pay\/([^/]+)$/.exec(url.pathname)
      if (payRoute && req.method === 'POST') {
        const payment = pay(payRoute[1])
        send(res, payment ? 200 : 404, payment ?? { error: 'not_found' })
        return true
      }
      if (url.pathname === '/asaas/local/state' && req.method === 'GET') {
        send(res, 200, { payments: [...payments.values()], transfers: [...transfers.values()], balance })
        return true
      }
      if (url.pathname.startsWith('/resend/')) {
        await handleResend(req, res, url)
        return true
      }
      return false
    },
    pay,
    payments,
    transfers,
    emails,
    /** Programa uma falha na próxima chamada (status HTTP, ou -1 para derrubar a conexão). */
    failNext: (route: string, status: number) => failNext.set(route, status),
    /** Espera os webhooks e transferências em andamento. */
    async settle() {
      while (pending.length) await Promise.all(pending.splice(0))
    },
  }
}
