-- =============================================================================
-- Zé do Carro — 06 Financeiro: estrutura
--
-- Princípios:
--  * Valores monetários das tabelas novas em centavos inteiros (bigint). As
--    colunas antigas de pedidos continuam numeric(12,2), que também é exato.
--  * Nada financeiro é confirmado pelo aplicativo do cliente: pagamentos só
--    mudam de estado com dados oficiais do provedor (webhook autenticado e
--    consulta à API) ou por ato registrado da equipe financeira (modo manual).
--  * Razão contábil (financial_ledger), eventos financeiros e auditoria são
--    somente de inclusão: nada se altera nem se apaga.
--  * Toda regra comercial (comissão, prazo, taxa, preço) vem de tabela, nunca
--    de valor fixo no código, e o pedido guarda cópia imutável do que valeu.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Equipe da HUB: papéis internos. 'admin' opera a plataforma (credenciamento,
-- catálogo, comissões); 'finance' é o gestor financeiro (pagamentos, repasses,
-- estornos, disputas, contas de recebimento). Uma pessoa pode ter os dois.
-- -----------------------------------------------------------------------------
create table public.staff_roles (
  user_id uuid not null references public.profiles (id),
  role text not null check (role in ('admin', 'finance')),
  granted_by uuid references public.profiles (id),
  granted_at timestamptz not null default now(),
  primary key (user_id, role)
);
-- Quem já era da HUB continua com acesso completo.
insert into public.staff_roles (user_id, role)
select p.id, r from public.profiles p cross join unnest(array['admin', 'finance']) r where p.role = 'hub_admin';

-- -----------------------------------------------------------------------------
-- Regras gerais (linha única de settings): novos parâmetros financeiros.
-- -----------------------------------------------------------------------------
alter table public.settings
  -- 'asaas': cobrança Pix automática com confirmação por webhook.
  -- 'manual': Pix para a chave da HUB, confirmado pela equipe financeira com
  --           o identificador da transação (nunca pelo cliente).
  add column payment_provider text not null default 'asaas' check (payment_provider in ('asaas', 'manual')),
  -- 'asaas': transferência Pix automática na data do repasse.
  -- 'manual': a equipe financeira paga por fora e registra o comprovante.
  add column payout_mode text not null default 'asaas' check (payout_mode in ('asaas', 'manual')),
  add column payment_window_minutes integer not null default 30 check (payment_window_minutes between 10 and 1440),
  add column confirm_hours integer not null default 24 check (confirm_hours between 1 and 168),
  add column platform_fee numeric(12,2) not null default 0 check (platform_fee between 0 and 100),
  -- Valor mínimo de uma cobrança. Confira o mínimo vigente do provedor.
  add column min_charge_amount numeric(12,2) not null default 5.00 check (min_charge_amount between 1 and 100),
  add column payout_max_attempts integer not null default 5 check (payout_max_attempts between 1 and 20),
  -- Carência depois da aprovação de uma conta Pix nova antes do primeiro repasse.
  add column account_cooldown_hours integer not null default 24 check (account_cooldown_hours between 0 and 168),
  add column setup_code_role text not null default 'admin' check (setup_code_role in ('admin', 'finance'));

-- -----------------------------------------------------------------------------
-- Catálogo: categorias, regiões, preço por região e promoções
-- -----------------------------------------------------------------------------
create table public.service_categories (
  code text primary key check (code ~ '^[a-z_]{3,30}$'),
  name text not null check (length(btrim(name)) between 3 and 60),
  sort integer not null default 0,
  active boolean not null default true
);

alter table public.services add column category_code text references public.service_categories (code);

create table public.regions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[a-z_]{3,40}$'),
  name text not null check (length(btrim(name)) between 3 and 80),
  uf char(2) not null check (uf ~ '^[A-Z]{2}$'),
  center_lat double precision not null check (center_lat between -90 and 90),
  center_lng double precision not null check (center_lng between -180 and 180),
  radius_km integer not null check (radius_km between 1 and 300),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.settings add column default_region_id uuid references public.regions (id);

create table public.service_prices (
  service_id uuid not null references public.services (id),
  region_id uuid not null references public.regions (id),
  price numeric(12,2) not null check (price > 0),
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (service_id, region_id)
);

-- Promoções automáticas (sem cupom), custeadas pela plataforma: o líquido do
-- prestador é calculado sobre o preço de tabela, nunca sobre o desconto.
create table public.promotions (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 3 and 80),
  kind text not null check (kind in ('percent', 'fixed')),
  value numeric(12,2) not null check (value > 0),
  service_id uuid references public.services (id),
  category_code text references public.service_categories (code),
  region_id uuid references public.regions (id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  max_redemptions integer check (max_redemptions > 0),
  redemptions integer not null default 0,
  active boolean not null default true,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  check (ends_at > starts_at),
  check (kind <> 'percent' or value < 100)
);

-- Comissões diferentes da padrão (settings.commission_percent). Prioridade:
-- prestador > campanha > categoria > padrão. Uma regra não se edita: encerra-se
-- e cria-se outra, para que nenhum pedido mude retroativamente.
create table public.commission_rules (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 3 and 80),
  scope text not null check (scope in ('category', 'provider', 'campaign')),
  category_code text references public.service_categories (code),
  provider_id uuid references public.providers (id),
  percent numeric(5,2) not null check (percent between 0 and 60),
  starts_at timestamptz,
  ends_at timestamptz,
  active boolean not null default true,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  check (ends_at is null or starts_at is null or ends_at > starts_at),
  check (scope <> 'category' or (category_code is not null and provider_id is null)),
  check (scope <> 'provider' or provider_id is not null),
  check (scope <> 'campaign' or (starts_at is not null and ends_at is not null and provider_id is null))
);

-- -----------------------------------------------------------------------------
-- Pedido: cópia imutável das condições comerciais e estado financeiro
-- -----------------------------------------------------------------------------
alter table public.requests
  add column region_id uuid references public.regions (id),
  add column discount_amount numeric(12,2) not null default 0 check (discount_amount >= 0),
  add column promotion_id uuid references public.promotions (id),
  add column fee_amount numeric(12,2) not null default 0 check (fee_amount >= 0),
  -- Comissão sem regra de prestador; volta a valer se o prestador desistir.
  add column base_commission_percent numeric(5,2),
  add column commission_rule_id uuid references public.commission_rules (id),
  add column payout_days_snapshot integer,
  add column pricing_snapshot jsonb not null default '{}'::jsonb,
  add column financial_status text not null default 'pending_payment' check (financial_status in (
    'pending_payment', 'payment_confirmed', 'service_in_progress', 'service_completed',
    'payout_scheduled', 'payout_processing', 'payout_completed', 'payout_failed',
    'disputed', 'refund_pending', 'refunded', 'cancelled')),
  add column payment_due_at timestamptz,
  add column completion_deadline timestamptz,
  add column completion_confirmed_at timestamptz,
  add column completion_confirmed_by text check (completion_confirmed_by in ('customer', 'auto', 'finance')),
  -- Jornal contábil do reconhecimento (conclusão confirmada); nulo antes disso.
  add column recognized_journal uuid;

update public.requests set base_commission_percent = commission_percent where base_commission_percent is null;
update public.requests set financial_status = case
    when status = 'cancelled' then 'cancelled'
    when payout_status = 'paid' then 'payout_completed'
    when payment_status = 'paid' then 'payout_scheduled'
    when status = 'completed' then 'service_completed'
    when status = 'in_progress' then 'service_in_progress'
    else 'pending_payment' end;
create index requests_financial on public.requests (financial_status);

-- Histórico de mudanças do estado financeiro (somente inclusão).
create table public.financial_events (
  id bigint generated always as identity primary key,
  request_id uuid not null references public.requests (id),
  from_status text,
  to_status text not null,
  actor_id uuid,
  note text,
  created_at timestamptz not null default now()
);
create index financial_events_request on public.financial_events (request_id, id);

create table public.disputes (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.requests (id),
  opened_by uuid references public.profiles (id),
  opened_role text not null check (opened_role in ('customer', 'provider', 'finance')),
  reason text not null check (length(btrim(reason)) >= 10),
  previous_financial_status text not null,
  status text not null default 'open' check (status in ('open', 'resolved_provider', 'resolved_customer')),
  resolution_note text,
  resolved_by uuid references public.profiles (id),
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index disputes_one_open on public.disputes (request_id) where status = 'open';

-- -----------------------------------------------------------------------------
-- Pagamentos
-- -----------------------------------------------------------------------------
-- Dado de cobrança do cliente, separado do perfil (segregação e LGPD): o CPF só
-- existe para emitir a cobrança no provedor.
create table public.payment_customers (
  profile_id uuid primary key references public.profiles (id),
  tax_id text not null check (tax_id ~ '^[0-9]{11}$' or tax_id ~ '^[0-9]{14}$'),
  provider text not null default 'asaas',
  external_id text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.requests (id),
  extra_id uuid references public.request_extras (id),
  kind text not null check (kind in ('service', 'extra')),
  method text not null check (method in ('pix_asaas', 'pix_manual')),
  status text not null default 'creating' check (status in (
    'creating', 'pending', 'confirmed', 'expired', 'cancelled', 'failed', 'refund_pending', 'refunded')),
  amount_cents bigint not null check (amount_cents > 0),
  -- Informados pelo provedor na confirmação (valor líquido e tarifa).
  net_cents bigint check (net_cents >= 0),
  fee_cents bigint check (fee_cents >= 0),
  -- Referência externa enviada ao provedor; identifica esta tentativa.
  attempt_key uuid not null unique default gen_random_uuid(),
  external_id text unique,
  provider_status text,
  pix_payload text,
  pix_qr_image text,
  pix_expires_at timestamptz,
  due_at timestamptz,
  -- Pagamento que chegou sem pedido à espera (atrasado ou duplicado): é estornado.
  orphan_reason text check (orphan_reason in ('duplicate', 'late_payment', 'amount_mismatch')),
  manual_reference text,
  confirmed_by uuid references public.profiles (id),
  confirmed_at timestamptz,
  refunded_at timestamptz,
  cancelled_at timestamptz,
  remote_cancel_pending boolean not null default false,
  last_synced_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((kind = 'extra') = (extra_id is not null))
);
create index payments_request on public.payments (request_id, created_at);
-- No máximo uma cobrança em aberto por pedido e item.
create unique index payments_one_open on public.payments (request_id, coalesce(extra_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status in ('creating', 'pending');
-- No máximo um pagamento válido (não órfão) confirmado por pedido e item.
create unique index payments_one_confirmed on public.payments (request_id, coalesce(extra_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status in ('confirmed', 'refund_pending', 'refunded') and orphan_reason is null;

create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments (id),
  amount_cents bigint not null check (amount_cents > 0),
  reason text not null check (reason in ('cancelled_before_service', 'duplicate', 'late_payment', 'amount_mismatch', 'dispute', 'finance')),
  note text,
  status text not null default 'requested' check (status in ('requested', 'processing', 'done', 'failed')),
  requested_by uuid references public.profiles (id),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  external_status text,
  last_error text,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  done_at timestamptz
);
-- Um estorno por pagamento (integral): impede estorno em dobro.
create unique index refunds_one_per_payment on public.refunds (payment_id) where status <> 'failed';

-- -----------------------------------------------------------------------------
-- Contas de recebimento dos prestadores
-- -----------------------------------------------------------------------------
create table public.provider_payment_accounts (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.providers (id),
  pix_key_type text not null check (pix_key_type in ('CPF', 'CNPJ', 'EMAIL', 'PHONE', 'EVP')),
  pix_key text not null check (length(pix_key) between 3 and 140),
  holder_name text not null check (length(btrim(holder_name)) between 3 and 160),
  -- Sempre o CPF/CNPJ do próprio credenciamento: o repasse não vai para terceiros.
  holder_doc text not null check (holder_doc ~ '^[0-9]{11}$' or holder_doc ~ '^[0-9]{14}$'),
  status text not null default 'pending_review' check (status in ('pending_review', 'active', 'rejected', 'replaced')),
  review_note text,
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  usable_from timestamptz,
  created_at timestamptz not null default now()
);
create unique index provider_accounts_one_active on public.provider_payment_accounts (provider_id) where status = 'active';
create unique index provider_accounts_one_pending on public.provider_payment_accounts (provider_id) where status = 'pending_review';

-- -----------------------------------------------------------------------------
-- Repasses
-- -----------------------------------------------------------------------------
create table public.payouts (
  id uuid primary key default gen_random_uuid(),
  -- Um repasse por pedido: a base da proteção contra repasse em dobro.
  request_id uuid not null unique references public.requests (id),
  provider_id uuid not null references public.providers (id),
  amount_cents bigint not null check (amount_cents > 0),
  status text not null default 'scheduled' check (status in ('scheduled', 'on_hold', 'processing', 'completed', 'failed', 'cancelled')),
  scheduled_for timestamptz not null,
  hold_reason text,
  account_id uuid references public.provider_payment_accounts (id),
  pix_key_type text,
  pix_key text,
  attempts integer not null default 0,
  next_attempt_at timestamptz,
  claim_token uuid,
  claimed_at timestamptz,
  -- A chamada ao provedor não teve resposta: não se tenta de novo sem conciliar.
  uncertain boolean not null default false,
  final_failure boolean not null default false,
  external_id text unique,
  external_status text,
  fee_cents bigint check (fee_cents >= 0),
  fail_reason text,
  manual_reference text,
  completed_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index payouts_due on public.payouts (scheduled_for) where status in ('scheduled', 'failed');
create index payouts_provider on public.payouts (provider_id, created_at desc);

create table public.payout_attempts (
  id bigint generated always as identity primary key,
  payout_id uuid not null references public.payouts (id),
  attempt integer not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  outcome text check (outcome in ('created', 'failed', 'uncertain')),
  external_id text,
  error text
);
create index payout_attempts_payout on public.payout_attempts (payout_id, id);

-- Saques da própria HUB (retirada da receita) liberados pela equipe financeira.
-- Com o mecanismo de validação de saque do Asaas ligado, toda transferência que
-- não for um repasse conhecido nem uma destas autorizações é recusada.
create table public.withdrawal_authorizations (
  id uuid primary key default gen_random_uuid(),
  amount_cents bigint not null check (amount_cents > 0),
  -- Chave Pix de destino: o saque só é aprovado para ela.
  pix_key text not null check (length(btrim(pix_key)) >= 3),
  note text not null check (length(btrim(note)) >= 5),
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  transfer_id text unique
);

-- -----------------------------------------------------------------------------
-- Razão contábil em partidas dobradas (somente inclusão)
--   cash_gateway         saldo no provedor de pagamentos (ativo)
--   customer_funds_held  valores recebidos de clientes ainda não reconhecidos
--   provider_payable     devido aos prestadores
--   provider_receivable  devido pelos prestadores (estorno após repasse)
--   platform_revenue     receita da plataforma (comissão e taxa)
--   gateway_fees         tarifas do provedor (despesa)
--   promotion_subsidy    descontos custeados pela plataforma (despesa)
-- -----------------------------------------------------------------------------
create table public.financial_ledger (
  id bigint generated always as identity primary key,
  journal_id uuid not null,
  account text not null check (account in ('cash_gateway', 'customer_funds_held', 'provider_payable', 'provider_receivable',
    'platform_revenue', 'gateway_fees', 'promotion_subsidy')),
  direction char(1) not null check (direction in ('D', 'C')),
  amount_cents bigint not null check (amount_cents > 0),
  request_id uuid references public.requests (id),
  payment_id uuid references public.payments (id),
  payout_id uuid references public.payouts (id),
  refund_id uuid references public.refunds (id),
  provider_id uuid references public.providers (id),
  memo text not null,
  created_at timestamptz not null default now()
);
create index ledger_journal on public.financial_ledger (journal_id);
create index ledger_request on public.financial_ledger (request_id);
create index ledger_account on public.financial_ledger (account, created_at);

-- -----------------------------------------------------------------------------
-- Webhooks recebidos (idempotência por id do evento) e auditoria
-- -----------------------------------------------------------------------------
create table public.webhook_events (
  id bigint generated always as identity primary key,
  provider text not null,
  event_id text not null check (length(event_id) between 1 and 200),
  event_type text not null check (length(event_type) between 1 and 100),
  resource_id text,
  payload jsonb not null,
  status text not null default 'received' check (status in ('received', 'processed', 'ignored', 'failed')),
  attempts integer not null default 0,
  last_error text,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (provider, event_id)
);
create index webhook_events_pending on public.webhook_events (received_at) where status in ('received', 'failed');

create table public.audit_logs (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor_id uuid,
  actor_role text,
  action text not null,
  entity text not null,
  entity_id text,
  before jsonb,
  after jsonb,
  note text
);
create index audit_logs_entity on public.audit_logs (entity, entity_id, id desc);

-- Fila e registro de e-mails transacionais (outbox transacional: o e-mail entra
-- na fila na mesma transação do fato que o motiva).
create table public.notification_logs (
  id bigint generated always as identity primary key,
  channel text not null default 'email' check (channel in ('email')),
  template text not null check (template ~ '^[a-z_]{3,40}$'),
  user_id uuid references public.profiles (id),
  to_email text,
  data jsonb not null default '{}'::jsonb,
  idempotency_key text not null unique check (length(idempotency_key) between 8 and 200),
  status text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed', 'skipped')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  provider_message_id text,
  last_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  updated_at timestamptz not null default now()
);
create index notification_logs_queue on public.notification_logs (next_attempt_at) where status in ('queued', 'sending');

-- -----------------------------------------------------------------------------
-- RLS ligado nas tabelas novas, sem políticas (acesso só pelas funções).
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
