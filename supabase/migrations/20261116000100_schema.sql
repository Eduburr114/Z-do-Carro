-- =============================================================================
-- Zé do Carro — 01 Estrutura
-- Marketplace de serviços automotivos móveis: clientes pedem, prestadores
-- credenciados aceitam e executam, a HUB credencia, intermedia e cuida da
-- qualidade.
--
-- Regra geral: negação por padrão. Nenhuma tabela é lida ou escrita direto pela
-- API; tudo passa por funções (RPC) que conferem quem chama. O RLS fica ligado
-- e sem políticas: mesmo que um privilégio vaze, nenhuma linha aparece.
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

create schema if not exists app;
revoke all on schema app from public;

alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
alter default privileges revoke execute on functions from public;

-- -----------------------------------------------------------------------------
-- Tipos
-- -----------------------------------------------------------------------------
create type public.user_role as enum ('customer', 'provider', 'hub_admin');
create type public.provider_status as enum ('draft', 'pending', 'approved', 'rejected', 'suspended', 'closed');
create type public.qualification_status as enum ('requested', 'approved', 'rejected');
create type public.request_status as enum ('searching', 'accepted', 'en_route', 'in_progress', 'completed', 'cancelled');
create type public.payment_status as enum ('pending', 'paid', 'refunded');
create type public.payout_status as enum ('none', 'pending', 'paid');
create type public.extra_status as enum ('proposed', 'approved', 'rejected');

-- -----------------------------------------------------------------------------
-- Pessoas
-- -----------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete restrict,
  full_name text not null check (length(btrim(full_name)) between 3 and 120),
  phone text not null check (phone ~ '^[0-9]{10,13}$'),
  role public.user_role not null,
  created_at timestamptz not null default now()
);

create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles (id),
  plate text not null check (plate ~ '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$'),
  brand text not null check (length(btrim(brand)) between 2 and 40),
  model text not null check (length(btrim(model)) between 1 and 60),
  year integer check (year between 1950 and 2100),
  archived boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index vehicles_plate_per_customer on public.vehicles (customer_id, plate) where not archived;

-- -----------------------------------------------------------------------------
-- Catálogo e regras da plataforma
-- -----------------------------------------------------------------------------
create table public.services (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[a-z_]{3,40}$'),
  name text not null check (length(btrim(name)) between 3 and 80),
  description text not null default '',
  base_price numeric(12,2) not null check (base_price > 0),
  est_minutes integer not null check (est_minutes between 5 and 600),
  active boolean not null default true,
  sort integer not null default 0
);

-- Uma única linha. O percentual e o prazo correspondem ao Anexo Financeiro do
-- contrato de credenciamento (cláusulas 7.2 e 7.5).
create table public.settings (
  id boolean primary key default true check (id),
  commission_percent numeric(5,2) not null default 20.00 check (commission_percent between 0 and 60),
  payout_days integer not null default 7 check (payout_days between 0 and 60),
  search_radius_km integer not null default 25 check (search_radius_km between 1 and 200),
  updated_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Prestadores credenciados
-- -----------------------------------------------------------------------------
create table public.providers (
  id uuid primary key references public.profiles (id),
  status public.provider_status not null default 'draft',
  doc_type text check (doc_type in ('cpf', 'cnpj')),
  doc_number text check (doc_number ~ '^[0-9]{11}$' or doc_number ~ '^[0-9]{14}$'),
  legal_name text check (length(btrim(legal_name)) between 3 and 160),
  city text check (length(btrim(city)) between 2 and 80),
  experience text not null default '',
  base_lat double precision check (base_lat between -90 and 90),
  base_lng double precision check (base_lng between -180 and 180),
  radius_km integer not null default 20 check (radius_km between 1 and 200),
  -- A conexão é sempre iniciativa do prestador (cláusula 3.2).
  online boolean not null default false,
  last_lat double precision,
  last_lng double precision,
  last_seen_at timestamptz,
  review_note text,
  applied_at timestamptz,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);

-- Habilitação por serviço (cláusula 4): cada serviço é aprovado separadamente.
create table public.provider_services (
  provider_id uuid not null references public.providers (id),
  service_id uuid not null references public.services (id),
  status public.qualification_status not null default 'requested',
  decided_at timestamptz,
  primary key (provider_id, service_id)
);

-- -----------------------------------------------------------------------------
-- Contrato de credenciamento: versões e aceite eletrônico (cláusula 15.1)
-- -----------------------------------------------------------------------------
create table public.contract_versions (
  id uuid primary key default gen_random_uuid(),
  version text not null unique,
  title text not null,
  body text not null,
  body_sha256 text not null,
  is_current boolean not null default false,
  published_at timestamptz not null default now()
);
create unique index contract_one_current on public.contract_versions (is_current) where is_current;

-- Registro do aceite: quem, quando, de onde e a impressão digital do texto
-- aceito, com as condições financeiras vigentes naquele momento. Não se altera.
create table public.contract_acceptances (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.providers (id),
  contract_version_id uuid not null references public.contract_versions (id),
  signer_name text not null,
  signer_doc text not null,
  body_sha256 text not null,
  commission_percent numeric(5,2) not null,
  payout_days integer not null,
  ip text,
  user_agent text,
  accepted_at timestamptz not null default now(),
  unique (provider_id, contract_version_id)
);

-- Suspensão com motivo, contestação e revisão (cláusula 11).
create table public.suspensions (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.providers (id),
  reason text not null check (length(btrim(reason)) >= 10),
  precautionary boolean not null default false,
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  contest_text text,
  contested_at timestamptz,
  resolution text check (resolution in ('upheld', 'lifted')),
  resolution_note text,
  resolved_by uuid references public.profiles (id),
  resolved_at timestamptz
);
create unique index suspensions_one_open on public.suspensions (provider_id) where resolved_at is null;

-- -----------------------------------------------------------------------------
-- Pedidos de serviço
-- -----------------------------------------------------------------------------
create sequence public.request_number_seq start 1001;

create table public.requests (
  id uuid primary key default gen_random_uuid(),
  number integer not null unique default nextval('public.request_number_seq'),
  customer_id uuid not null references public.profiles (id),
  vehicle_id uuid not null references public.vehicles (id),
  service_id uuid not null references public.services (id),
  provider_id uuid references public.providers (id),
  status public.request_status not null default 'searching',
  address text not null check (length(btrim(address)) between 5 and 240),
  lat double precision check (lat between -90 and 90),
  lng double precision check (lng between -180 and 180),
  notes text not null default '',
  -- Valores congelados no pedido: o prestador vê o líquido antes de aceitar
  -- (cláusulas 6.1 e 7.3) e a comissão não muda depois.
  price numeric(12,2) not null check (price > 0),
  commission_percent numeric(5,2) not null,
  extras_total numeric(12,2) not null default 0,
  total numeric(12,2) not null,
  commission_amount numeric(12,2) not null,
  provider_net numeric(12,2) not null,
  payment_status public.payment_status not null default 'pending',
  payout_status public.payout_status not null default 'none',
  payout_due date,
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  paid_at timestamptz,
  payout_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by public.user_role,
  cancel_reason text
);
create index requests_customer on public.requests (customer_id, created_at desc);
create index requests_provider on public.requests (provider_id, created_at desc);
create index requests_searching on public.requests (created_at) where status = 'searching';
-- Um prestador executa um atendimento por vez.
create unique index requests_one_active_per_provider on public.requests (provider_id)
  where status in ('accepted', 'en_route', 'in_progress');

-- Recusas: servem só para não mostrar o mesmo pedido de novo ao prestador.
-- Não entram em nota, classificação nem punição (cláusulas 3.3 e 10.3).
create table public.request_declines (
  request_id uuid not null references public.requests (id),
  provider_id uuid not null references public.providers (id),
  created_at timestamptz not null default now(),
  primary key (request_id, provider_id)
);

-- Serviços adicionais: só com orçamento e autorização do cliente (cláusula 6.5).
create table public.request_extras (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.requests (id),
  description text not null check (length(btrim(description)) between 3 and 200),
  price numeric(12,2) not null check (price > 0),
  status public.extra_status not null default 'proposed',
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

create table public.request_events (
  id bigint generated always as identity primary key,
  request_id uuid not null references public.requests (id),
  kind text not null,
  actor public.user_role,
  note text,
  created_at timestamptz not null default now()
);
create index request_events_request on public.request_events (request_id, id);

create table public.reviews (
  request_id uuid primary key references public.requests (id),
  provider_id uuid not null references public.providers (id),
  rating integer not null check (rating between 1 and 5),
  comment text not null default '',
  created_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- RLS ligado em tudo, sem políticas: acesso somente pelas funções.
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
