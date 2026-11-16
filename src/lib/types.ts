export type Role = 'customer' | 'provider' | 'hub_admin'
export type StaffRole = 'admin' | 'finance'
export type ProviderStatus = 'draft' | 'pending' | 'approved' | 'rejected' | 'suspended' | 'closed'
export type RequestStatus = 'awaiting_payment' | 'searching' | 'accepted' | 'en_route' | 'in_progress' | 'completed' | 'cancelled'
export type Rating = { average: number | null; count: number }

export type Service = {
  id: string; code: string; name: string; description: string; base_price: number; est_minutes: number; active?: boolean
  category_code: string; category_name?: string
}
export type Quote = {
  service_id: string; service_name: string; category_code: string; region_name: string | null
  list_price: number; discount: number; promotion_name: string | null; fee: number; total: number; min_charge: number
}
export type Vehicle = { id: string; plate: string; brand: string; model: string; year: number | null }

export type ServiceRequest = {
  id: string
  number: number
  status: RequestStatus
  service: { id: string; name: string; est_minutes: number }
  address: string
  lat: number | null
  lng: number | null
  notes: string
  distance_km: number | null
  price: number
  extras_total: number
  total: number
  commission_percent: number
  commission_amount: number
  provider_net: number
  payment_status: 'pending' | 'paid' | 'refunded'
  payout_status: 'none' | 'pending' | 'paid'
  payout_due: string | null
  created_at: string
  accepted_at: string | null
  started_at: string | null
  completed_at: string | null
  paid_at: string | null
  payment_claimed_at: string | null
  cancelled_at: string | null
  cancelled_by: Role | null
  cancel_reason: string | null
  vehicle: { brand: string; model: string; year: number | null; plate?: string }
  customer: { name: string; phone: string } | null
  provider: { id: string; name: string; phone: string; rating: Rating; lat: number | null; lng: number | null; distance_km: number | null } | null
  extras: { id: string; description: string; price: number; status: 'proposed' | 'approved' | 'rejected' | 'cancelled'; paid: boolean }[]
  events: { kind: string; actor: Role | null; note: string | null; at: string }[]
  review: { rating: number; comment: string } | null
  financial_status: FinancialStatus
  discount_amount: number
  fee_amount: number
  promotion_name: string | null
  region_name: string | null
  payment_due_at: string | null
  completion_deadline: string | null
  completion_confirmed_at: string | null
  completion_confirmed_by: 'customer' | 'auto' | 'finance' | null
  payout: { status: PayoutStatus; scheduled_for: string; completed_at: string | null; amount: number; hold_reason: string | null } | null
  dispute: { id: string; reason: string; opened_role: string; status: 'open' | 'resolved_provider' | 'resolved_customer'; created_at: string; resolution_note: string | null } | null
  /** Só para o cliente e a equipe. */
  payments?: CustomerPayment[]
}

export type FinancialStatus =
  | 'pending_payment' | 'payment_confirmed' | 'service_in_progress' | 'service_completed'
  | 'payout_scheduled' | 'payout_processing' | 'payout_completed' | 'payout_failed'
  | 'disputed' | 'refund_pending' | 'refunded' | 'cancelled'
export type PayoutStatus = 'scheduled' | 'on_hold' | 'processing' | 'completed' | 'failed' | 'cancelled'
export type PaymentStatus = 'creating' | 'pending' | 'confirmed' | 'expired' | 'cancelled' | 'failed' | 'refund_pending' | 'refunded'

export type CustomerPayment = {
  id: string
  kind: 'service' | 'extra'
  extra_id: string | null
  method: 'pix_asaas' | 'pix_manual'
  status: PaymentStatus
  amount: number
  pix_payload: string | null
  pix_qr_image: string | null
  pix_expires_at: string | null
  claimed: boolean
  orphan_reason: string | null
  created_at: string
  confirmed_at: string | null
  refunded_at: string | null
}

export type Suspension = {
  id: string
  reason: string
  precautionary: boolean
  created_at: string
  contest_text: string | null
  contested_at: string | null
  resolution?: 'upheld' | 'lifted' | null
  resolution_note?: string | null
  resolved_at?: string | null
}

export type ProviderHome = {
  status: ProviderStatus
  online: boolean
  city: string | null
  radius_km: number
  doc_type: 'cpf' | 'cnpj' | null
  legal_name: string | null
  review_note: string | null
  has_position: boolean
  contract_ok: boolean
  rating: Rating
  services: { id: string; name: string; status: 'requested' | 'approved' | 'rejected' }[]
  suspension: Suspension | null
  active_request: string | null
}

export type Contract = {
  id: string
  version: string
  title: string
  body: string
  body_sha256: string
  published_at: string
  commission_percent: number
  payout_days: number
  acceptance: { accepted_at: string; signer_name: string; commission_percent: number; payout_days: number } | null
}

export type DocumentKind = 'identity' | 'address' | 'certificate' | 'equipment' | 'other'
export type ProviderDocument = { id: string; kind: DocumentKind; file_name: string; mime: string; size: number; created_at: string }
export type PaymentInfo = { mode: 'asaas' | 'manual'; pix_key: string | null; pix_holder: string | null; has_tax_id: boolean }
