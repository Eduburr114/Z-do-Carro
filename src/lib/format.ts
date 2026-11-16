import type { ProviderStatus, RequestStatus } from '@/lib/types'

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
  paid: 'Pagamento confirmado',
  payout: 'Repasse feito ao prestador',
}
