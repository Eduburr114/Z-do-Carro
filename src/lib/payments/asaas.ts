import 'server-only'

/**
 * Cliente da API v3 do Asaas (https://docs.asaas.com).
 *
 * Conferido na documentação oficial:
 *  - Autenticação pelo cabeçalho `access_token`; sandbox em api-sandbox.asaas.com.
 *  - Cobrança Pix: POST /v3/payments com billingType PIX; QR Code em
 *    GET /v3/payments/{id}/pixQrCode (encodedImage, payload, expirationDate).
 *  - Transferência Pix: POST /v3/transfers com pixAddressKey e pixAddressKeyType;
 *    consulta em GET /v3/transfers/{id}; situações PENDING, BANK_PROCESSING,
 *    DONE, CANCELLED, FAILED (e SCHEDULED, BLOCKED).
 *  - Estorno de Pix integral ou parcial; sem `value`, é integral.
 *  - Requisições GET devem ir sem corpo.
 *
 * A CONFIRMAR NO SANDBOX antes da produção (marcados com "confirmar"):
 *  - caminho exato do estorno (POST /v3/payments/{id}/refund);
 *  - filtro externalReference em GET /v3/payments;
 *  - campo externalReference e nome do campo de tarifa nas transferências;
 *  - GET /v3/finance/balance para a conciliação de saldo.
 */

export type AsaasEnvironment = 'sandbox' | 'production'

export const ASAAS_URLS: Record<AsaasEnvironment, string> = {
  sandbox: 'https://api-sandbox.asaas.com/v3',
  production: 'https://api.asaas.com/v3',
}

/** Erro de chamada ao provedor, já classificado para decisão de nova tentativa. */
export class GatewayError extends Error {
  constructor(
    message: string,
    readonly status: number | null,
    /** Vale tentar de novo depois (limite de requisições, indisponibilidade). */
    readonly retryable: boolean,
    /** Não se sabe se a operação foi feita (sem resposta depois do envio). */
    readonly uncertain: boolean,
  ) {
    super(message)
    this.name = 'GatewayError'
  }
}

export type AsaasPayment = {
  id: string
  status: string
  value: number
  netValue?: number
  externalReference?: string | null
  deleted?: boolean
  dueDate?: string
}
export type AsaasPixQrCode = { encodedImage: string; payload: string; expirationDate?: string | null }
export type AsaasTransfer = {
  id: string
  status: string
  value: number
  externalReference?: string | null
  failReason?: string | null
  transferFee?: number | null
}
export type PixKeyType = 'CPF' | 'CNPJ' | 'EMAIL' | 'PHONE' | 'EVP'

export type PaymentGateway = {
  createCustomer(input: { name: string; cpfCnpj: string; email?: string | null; mobilePhone?: string | null; externalReference: string }): Promise<{ id: string }>
  createPixPayment(input: { customer: string; valueCents: number; dueDate: string; description: string; externalReference: string }): Promise<AsaasPayment>
  getPixQrCode(paymentId: string): Promise<AsaasPixQrCode>
  getPayment(paymentId: string): Promise<AsaasPayment>
  findPaymentsByReference(externalReference: string): Promise<AsaasPayment[]>
  deletePayment(paymentId: string): Promise<void>
  refundPayment(paymentId: string, description: string): Promise<AsaasPayment>
  createPixTransfer(input: { valueCents: number; pixKey: string; pixKeyType: PixKeyType; description: string; externalReference: string }): Promise<AsaasTransfer>
  getTransfer(transferId: string): Promise<AsaasTransfer>
  getBalance(): Promise<{ balance: number }>
}

export const toCents = (value: number | string | null | undefined): number => Math.round(Number(value ?? 0) * 100)
const toReais = (cents: number): number => Math.round(cents) / 100

type Options = { apiKey: string; environment: AsaasEnvironment; baseUrl?: string; timeoutMs?: number; fetchImpl?: typeof fetch }

export function createAsaasClient(options: Options): PaymentGateway {
  const base = (options.baseUrl ?? ASAAS_URLS[options.environment]).replace(/\/$/, '')
  const timeoutMs = options.timeoutMs ?? 15_000
  const doFetch = options.fetchImpl ?? fetch

  async function call<T>(method: 'GET' | 'POST' | 'DELETE', path: string, body?: unknown): Promise<T> {
    let response: Response
    try {
      response = await doFetch(`${base}${path}`, {
        method,
        headers: {
          access_token: options.apiKey,
          'Content-Type': 'application/json',
          Accept: 'application/json',
          // Identificação genérica do cliente HTTP (exigida pelo Asaas em contas novas).
          'User-Agent': 'ze-do-carro-api/1.0',
        },
        // GET sem corpo (o Asaas pode responder 403 a GET com corpo).
        body: method === 'GET' || body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(timeoutMs),
        cache: 'no-store',
      })
    } catch (error) {
      const refused = (error as { cause?: { code?: string } }).cause?.code === 'ECONNREFUSED'
      // Sem resposta: num GET basta tentar de novo; numa escrita, não se sabe se foi feita.
      throw new GatewayError(`Sem resposta do Asaas (${method} ${path.split('?')[0]})`, null, true, method !== 'GET' && !refused)
    }
    const text = await response.text()
    let data: unknown = null
    try {
      data = text ? JSON.parse(text) : null
    } catch {
      data = null
    }
    if (!response.ok) {
      const errors = (data as { errors?: { code?: string; description?: string }[] } | null)?.errors
      const detail = errors?.map((e) => e.description ?? e.code).join('; ') || `HTTP ${response.status}`
      const status = response.status
      const retryable = status === 429 || status >= 500 || status === 408
      // Erro 5xx numa escrita: pode ter sido processada. Tratado como incerto.
      const uncertain = method !== 'GET' && (status >= 500 || status === 408)
      throw new GatewayError(`Asaas: ${detail}`, status, retryable, uncertain)
    }
    return data as T
  }

  return {
    createCustomer: (input) =>
      call('POST', '/customers', {
        name: input.name,
        cpfCnpj: input.cpfCnpj,
        email: input.email ?? undefined,
        mobilePhone: input.mobilePhone ?? undefined,
        externalReference: input.externalReference,
        // Os avisos ao cliente são do Zé do Carro, não do Asaas.
        notificationDisabled: true,
      }),
    createPixPayment: (input) =>
      call('POST', '/payments', {
        customer: input.customer,
        billingType: 'PIX',
        value: toReais(input.valueCents),
        dueDate: input.dueDate,
        description: input.description.slice(0, 500),
        externalReference: input.externalReference,
      }),
    getPixQrCode: (id) => call('GET', `/payments/${encodeURIComponent(id)}/pixQrCode`),
    getPayment: (id) => call('GET', `/payments/${encodeURIComponent(id)}`),
    // confirmar: filtro externalReference na listagem de cobranças.
    findPaymentsByReference: async (ref) =>
      (await call<{ data?: AsaasPayment[] }>('GET', `/payments?externalReference=${encodeURIComponent(ref)}`)).data ?? [],
    deletePayment: async (id) => {
      await call('DELETE', `/payments/${encodeURIComponent(id)}`)
    },
    // confirmar: caminho do estorno no sandbox.
    refundPayment: (id, description) => call('POST', `/payments/${encodeURIComponent(id)}/refund`, { description: description.slice(0, 500) }),
    createPixTransfer: (input) =>
      call('POST', '/transfers', {
        value: toReais(input.valueCents),
        operationType: 'PIX',
        pixAddressKey: input.pixKey,
        pixAddressKeyType: input.pixKeyType,
        description: input.description.slice(0, 140),
        // confirmar: devolvido nos webhooks e na validação de saque.
        externalReference: input.externalReference,
      }),
    getTransfer: (id) => call('GET', `/transfers/${encodeURIComponent(id)}`),
    // confirmar: endpoint de saldo.
    getBalance: () => call('GET', '/finance/balance'),
  }
}
