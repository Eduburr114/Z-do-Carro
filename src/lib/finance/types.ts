import type { PaymentGateway } from '@/lib/payments/asaas'
import type { Mailer } from '@/lib/email/outbox'

/** Chamada de função do banco com a chave secreta (papel service_role). */
export type ServiceRpc = <T = unknown>(name: string, args?: Record<string, unknown>) => Promise<T>

export class ServiceRpcError extends Error {
  constructor(
    readonly fn: string,
    readonly code: string,
    message: string,
  ) {
    super(`${fn}: ${message}`)
    this.name = 'ServiceRpcError'
  }
}

/** Tudo de que os fluxos financeiros dependem; injetável nos testes. */
export type FinanceDeps = {
  rpc: ServiceRpc
  gateway: PaymentGateway | null
  /** Token esperado no cabeçalho asaas-access-token dos webhooks. */
  webhookToken: string | null
  /** Token do mecanismo de validação de saque; ligado = proteção extra contra repasse em dobro. */
  transferValidationToken: string | null
  mailer: Mailer | null
  appUrl: string
  now?: () => Date
  log?: (message: string, data?: Record<string, unknown>) => void
}

/** Resposta de payment_start quando a cobrança precisa ser criada no provedor. */
export type ChargeToCreate = {
  mode: 'asaas'
  action: 'create'
  payment_id: string
  attempt_key: string
  amount_cents: number
  description: string
  due_date: string
  customer: { profile_id: string; name: string; tax_id: string; phone: string; email: string | null; external_id: string | null }
}

export type PaymentStart =
  | ChargeToCreate
  | { mode: 'asaas' | 'manual'; action: 'existing' | 'wait'; payment_id: string }
