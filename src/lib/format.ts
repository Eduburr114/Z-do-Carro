import type { FinancialStatus, PaymentStatus, PayoutStatus, ProviderStatus, RequestStatus } from '@/lib/types'

const TZ = 'America/Fortaleza'
const money = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })
const dateTime = new Intl.DateTimeFormat('pt-BR', { timeZone: TZ, day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' })
const timeOnly = new Intl.DateTimeFormat('pt-BR', { timeZone: TZ, hour: '2-digit', minute: '2-digit' })

/** Valor vindo do banco (numeric) em reais. Só exibição. */
export function formatMoney(value: number | string | null | undefined): string {
  if (value === null || value === undefined || value === '') return '—'
  return money.format(Number(value))
}

export function formatDate(iso: string | null | undefined): string {
  if (!iso) return '—'
  const [y, m, d] = iso.slice(0, 10).split('-')
  return `${d}/${m}/${y}`
}

export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return '—'
  return dateTime.format(new Date(iso)).replace(',', ' às')
}

export function formatTime(iso: string | null | undefined): string {
  if (!iso) return '—'
  return timeOnly.format(new Date(iso))
}

export function formatPhone(digits: string): string {
  const d = digits.replace(/\D/g, '')
  if (d.length === 11) return `(${d.slice(0, 2)}) ${d.slice(2, 7)}-${d.slice(7)}`
  if (d.length === 10) return `(${d.slice(0, 2)}) ${d.slice(2, 6)}-${d.slice(6)}`
  return digits
}

export function formatDoc(doc: string | null): string {
  if (!doc) return '—'
  if (doc.length === 11) return `${doc.slice(0, 3)}.${doc.slice(3, 6)}.${doc.slice(6, 9)}-${doc.slice(9)}`
  if (doc.length === 14) return `${doc.slice(0, 2)}.${doc.slice(2, 5)}.${doc.slice(5, 8)}/${doc.slice(8, 12)}-${doc.slice(12)}`
  return doc
}

export function formatKm(km: number | null | undefined): string | null {
  if (km === null || km === undefined) return null
  return `${km.toLocaleString('pt-BR', { maximumFractionDigits: 1 })} km`
}

export function formatPercent(value: number | string): string {
  return `${Number(value).toLocaleString('pt-BR', { maximumFractionDigits: 2 })}%`
}

type Tone = 'neutral' | 'success' | 'warning' | 'danger' | 'info'

export const requestStatus: Record<RequestStatus, { label: string; tone: Tone }> = {
  awaiting_payment: { label: 'Aguardando pagamento', tone: 'warning' },
  searching: { label: 'Procurando prestador', tone: 'warning' },
  accepted: { label: 'Prestador confirmado', tone: 'info' },
  en_route: { label: 'A caminho', tone: 'info' },
  in_progress: { label: 'Em atendimento', tone: 'info' },
  completed: { label: 'Concluído', tone: 'success' },
  cancelled: { label: 'Cancelado', tone: 'neutral' },
}

export const providerStatus: Record<ProviderStatus, { label: string; tone: Tone }> = {
  draft: { label: 'Cadastro incompleto', tone: 'neutral' },
  pending: { label: 'Em análise', tone: 'warning' },
  approved: { label: 'Credenciado', tone: 'success' },
  rejected: { label: 'Não aprovado', tone: 'danger' },
  suspended: { label: 'Suspenso', tone: 'danger' },
  closed: { label: 'Encerrado', tone: 'neutral' },
}

export const eventLabel: Record<string, string> = {
  created: 'Pedido criado',
  accepted: 'Prestador aceitou',
  en_route: 'Prestador a caminho',
  in_progress: 'Serviço iniciado',
  completed: 'Serviço concluído',
  cancelled: 'Pedido cancelado',
  withdrawn: 'Prestador desistiu; buscando outro',
  extra_proposed: 'Orçamento adicional enviado',
  extra_approved: 'Adicional aprovado pelo cliente',
  extra_rejected: 'Adicional recusado pelo cliente',
  payment_claimed: 'Cliente informou o pagamento por Pix',
  paid: 'Pagamento confirmado pelo banco',
  payout: 'Repasse feito ao prestador',
  payment_expired: 'Prazo de pagamento encerrado',
  payment_orphan: 'Pagamento fora do fluxo (estorno automático)',
  extra_paid: 'Adicional pago',
  extra_cancelled: 'Adicional cancelado',
  completion_confirmed: 'Cliente confirmou o serviço',
  payout_scheduled: 'Repasse agendado',
  payout_on_hold: 'Repasse aguardando conta Pix',
  payout_completed: 'Repasse transferido',
  payout_failed: 'Repasse com falha',
  refund_requested: 'Estorno solicitado',
  refunded: 'Estorno concluído',
  dispute_opened: 'Disputa aberta',
  dispute_resolved: 'Disputa decidida',
}

export const financialStatus: Record<FinancialStatus, { label: string; tone: Tone }> = {
  pending_payment: { label: 'Aguardando pagamento', tone: 'warning' },
  payment_confirmed: { label: 'Pago', tone: 'success' },
  service_in_progress: { label: 'Em atendimento', tone: 'info' },
  service_completed: { label: 'Aguardando confirmação', tone: 'warning' },
  payout_scheduled: { label: 'Repasse agendado', tone: 'info' },
  payout_processing: { label: 'Repasse em processamento', tone: 'info' },
  payout_completed: { label: 'Repasse concluído', tone: 'success' },
  payout_failed: { label: 'Repasse com falha', tone: 'danger' },
  disputed: { label: 'Em disputa', tone: 'danger' },
  refund_pending: { label: 'Estorno em andamento', tone: 'warning' },
  refunded: { label: 'Estornado', tone: 'neutral' },
  cancelled: { label: 'Cancelado', tone: 'neutral' },
}

export const payoutStatus: Record<PayoutStatus, { label: string; tone: Tone }> = {
  scheduled: { label: 'Agendado', tone: 'info' },
  on_hold: { label: 'Retido', tone: 'warning' },
  processing: { label: 'Em processamento', tone: 'info' },
  completed: { label: 'Transferido', tone: 'success' },
  failed: { label: 'Com falha', tone: 'danger' },
  cancelled: { label: 'Cancelado', tone: 'neutral' },
}

export const paymentStatus: Record<PaymentStatus, { label: string; tone: Tone }> = {
  creating: { label: 'Gerando cobrança', tone: 'neutral' },
  pending: { label: 'Aguardando Pix', tone: 'warning' },
  confirmed: { label: 'Confirmado', tone: 'success' },
  expired: { label: 'Vencido', tone: 'neutral' },
  cancelled: { label: 'Cancelado', tone: 'neutral' },
  failed: { label: 'Não gerado', tone: 'danger' },
  refund_pending: { label: 'Estorno em andamento', tone: 'warning' },
  refunded: { label: 'Estornado', tone: 'neutral' },
}

/** Centavos ou reais vindos do banco, formatados como percentual com 2 casas. */
export const holdReason = (reason: string | null) =>
  !reason ? '' : reason === 'no_account' ? 'aguardando conta Pix conferida' : reason === 'dispute' ? 'disputa em análise' : reason.replace(/^finance: /, 'retido pela equipe: ')

export const documentKind: Record<string, string> = {
  identity: 'Documento de identificação',
  address: 'Comprovante de endereço',
  certificate: 'Certificado ou curso',
  equipment: 'Foto de equipamento',
  other: 'Outro',
}

export function formatSize(bytes: number): string {
  return bytes >= 1048576 ? `${(bytes / 1048576).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`
}
