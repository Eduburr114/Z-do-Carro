-- GERADO por scripts/gerar-instalacao.sh a partir de supabase/migrations. Não edite à mão.
-- Instala o banco do Zé do Carro em um projeto Supabase novo e vazio.

-- >>> 20261116000100_schema.sql
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
  -- Versão dos termos de uso e da política de privacidade aceitos no cadastro.
  terms_version text,
  terms_accepted_at timestamptz,
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
  -- Pagamento: sem chave Pix, o aplicativo fica em modo demonstração (pagamento
  -- simulado). Com a chave, o cliente paga por Pix à HUB e a HUB confirma.
  pix_key text check (length(btrim(pix_key)) between 5 and 140),
  pix_holder text check (length(btrim(pix_holder)) between 3 and 120),
  -- Código de ativação (só o hash) para criar um acesso da equipe da HUB.
  setup_code_hash text,
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
  -- Pix manual: o cliente avisa que pagou e a HUB confirma o recebimento.
  payment_claimed_at timestamptz,
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
-- Documentos do credenciamento (cláusulas 4.1 e 4.2): identidade, certificados
-- e fotos dos equipamentos. Ficam no banco, fora de qualquer endereço público;
-- só o próprio prestador e a HUB conseguem abrir.
-- -----------------------------------------------------------------------------
create table public.provider_documents (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.providers (id),
  kind text not null check (kind in ('identity', 'address', 'certificate', 'equipment', 'other')),
  file_name text not null check (length(file_name) between 1 and 120),
  mime text not null check (mime in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf')),
  size integer not null check (size between 1 and 3145728),
  content bytea not null,
  created_at timestamptz not null default now()
);
create index provider_documents_provider on public.provider_documents (provider_id, created_at);

-- -----------------------------------------------------------------------------
-- Avisos (dentro do aplicativo e por push)
-- -----------------------------------------------------------------------------
create table public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id),
  title text not null,
  body text not null,
  url text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  push_sent_at timestamptz
);
create index notifications_user on public.notifications (user_id, id desc);
create index notifications_push_pending on public.notifications (id) where push_sent_at is null;

create table public.push_subscriptions (
  endpoint text primary key check (endpoint ~ '^https://'),
  user_id uuid not null references public.profiles (id),
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
create index push_subscriptions_user on public.push_subscriptions (user_id);

-- Limite de tentativas (login, recuperação de senha, código de ativação).
create table public.rate_limits (
  key text primary key,
  count integer not null,
  window_start timestamptz not null default now()
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

-- >>> 20261116000200_functions.sql
-- =============================================================================
-- Zé do Carro — 02 Funções
-- Toda leitura e escrita do aplicativo passa por aqui. Cada função confere quem
-- chama (auth.uid()) e o papel no banco; nada vem confiado do cliente.
-- Erros: MESSAGE = código estável, DETAIL = texto pronto para o usuário.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Apoio interno (schema app, fora da API)
-- -----------------------------------------------------------------------------
create function app.fail(p_code text, p_detail text) returns void
language plpgsql set search_path = ''
as $$
begin
  raise exception using errcode = 'P0001', message = p_code, detail = p_detail;
end $$;

create function app.deny() returns void
language plpgsql set search_path = ''
as $$
begin
  raise exception using errcode = '42501', message = 'permission_denied';
end $$;

create function app.uid() returns uuid
language plpgsql stable set search_path = ''
as $$
declare v uuid := auth.uid();
begin
  if v is null then perform app.deny(); end if;
  return v;
end $$;

-- Confere o papel de quem chama e devolve o id.
create function app.require_role(p_role public.user_role) returns uuid
language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := app.uid();
begin
  if not exists (select 1 from public.profiles where id = v_uid and role = p_role) then
    perform app.deny();
  end if;
  return v_uid;
end $$;

-- Distância em km entre dois pontos (haversine). Nulo se faltar coordenada.
create function app.km(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns numeric language sql immutable set search_path = ''
as $$
  select case when lat1 is null or lng1 is null or lat2 is null or lng2 is null then null
  else round((2 * 6371 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  )))::numeric, 1) end
$$;

create function app.log(p_request uuid, p_kind text, p_actor public.user_role, p_note text default null) returns void
language sql security definer set search_path = ''
as $$
  insert into public.request_events (request_id, kind, actor, note) values (p_request, p_kind, p_actor, p_note)
$$;

-- Recalcula total, comissão e líquido do pedido a partir dos adicionais aprovados.
create function app.recalc(p_request uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_extras numeric(12,2);
begin
  select coalesce(sum(price), 0) into v_extras
  from public.request_extras where request_id = p_request and status = 'approved';
  update public.requests r set
    extras_total = v_extras,
    total = r.price + v_extras,
    commission_amount = round((r.price + v_extras) * r.commission_percent / 100, 2),
    provider_net = (r.price + v_extras) - round((r.price + v_extras) * r.commission_percent / 100, 2)
  where r.id = p_request;
end $$;

-- O prestador aceitou a versão vigente do contrato?
create function app.contract_ok(p_provider uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.contract_acceptances a
    join public.contract_versions v on v.id = a.contract_version_id and v.is_current
    where a.provider_id = p_provider)
$$;

create function app.rating(p_provider uuid) returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('average', round(avg(rating)::numeric, 1), 'count', count(*))
  from public.reviews where provider_id = p_provider
$$;

-- Pedido em JSON. p_view decide quanto de dado pessoal aparece (LGPD, 12.2):
-- 'offer' = prestador que ainda não aceitou: sem nome, telefone nem placa.
create function app.request_json(p_id uuid, p_view text, p_lat double precision default null, p_lng double precision default null)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'id', r.id, 'number', r.number, 'status', r.status,
    'service', jsonb_build_object('id', s.id, 'name', s.name, 'est_minutes', s.est_minutes),
    'address', r.address, 'lat', r.lat, 'lng', r.lng, 'notes', r.notes,
    'distance_km', app.km(p_lat, p_lng, r.lat, r.lng),
    'price', r.price, 'extras_total', r.extras_total, 'total', r.total,
    'commission_percent', r.commission_percent, 'commission_amount', r.commission_amount, 'provider_net', r.provider_net,
    'payment_status', r.payment_status, 'payout_status', r.payout_status, 'payout_due', r.payout_due,
    'created_at', r.created_at, 'accepted_at', r.accepted_at, 'started_at', r.started_at,
    'completed_at', r.completed_at, 'paid_at', r.paid_at, 'payment_claimed_at', r.payment_claimed_at, 'cancelled_at', r.cancelled_at,
    'cancelled_by', r.cancelled_by, 'cancel_reason', r.cancel_reason,
    'vehicle', case when p_view = 'offer'
      then jsonb_build_object('brand', v.brand, 'model', v.model, 'year', v.year)
      else jsonb_build_object('brand', v.brand, 'model', v.model, 'year', v.year, 'plate', v.plate) end,
    'customer', case when p_view = 'offer' then null
      else jsonb_build_object('name', c.full_name, 'phone', c.phone) end,
    'provider', case when r.provider_id is null then null
      else jsonb_build_object('id', pp.id, 'name', pp.full_name, 'phone', pp.phone,
        'rating', app.rating(r.provider_id), 'lat', pr.last_lat, 'lng', pr.last_lng,
        'distance_km', app.km(pr.last_lat, pr.last_lng, r.lat, r.lng)) end,
    'extras', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'description', e.description,
        'price', e.price, 'status', e.status) order by e.created_at)
      from public.request_extras e where e.request_id = r.id), '[]'::jsonb),
    'events', case when p_view = 'offer' then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object(
        'kind', ev.kind, 'actor', ev.actor, 'note', ev.note, 'at', ev.created_at) order by ev.id)
      from public.request_events ev where ev.request_id = r.id), '[]'::jsonb) end,
    'review', (select jsonb_build_object('rating', w.rating, 'comment', w.comment) from public.reviews w where w.request_id = r.id)
  )
  from public.requests r
  join public.services s on s.id = r.service_id
  join public.vehicles v on v.id = r.vehicle_id
  join public.profiles c on c.id = r.customer_id
  left join public.providers pr on pr.id = r.provider_id
  left join public.profiles pp on pp.id = r.provider_id
  where r.id = p_id
$$;

-- =============================================================================
-- Conta
-- =============================================================================
create function public.my_access() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'user_id', auth.uid(),
    'profile', (select jsonb_build_object('id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'role', p.role)
                from public.profiles p where p.id = auth.uid()),
    'provider', (select jsonb_build_object('status', pr.status, 'online', pr.online, 'contract_ok', app.contract_ok(pr.id))
                 from public.providers pr where pr.id = auth.uid()),
    'unread', (select count(*) from public.notifications n where n.user_id = auth.uid() and n.read_at is null))
$$;

-- Cadastro: só cliente ou prestador. Administradores da HUB são promovidos à parte.
create function public.register_profile(p_full_name text, p_phone text, p_role text, p_terms_version text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.uid();
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
begin
  if p_role not in ('customer', 'provider') then perform app.fail('invalid_role', 'Escolha cliente ou prestador.'); end if;
  if exists (select 1 from public.profiles where id = v_uid) then
    perform app.fail('profile_exists', 'Esta conta já tem cadastro.');
  end if;
  if length(btrim(coalesce(p_full_name, ''))) < 3 then perform app.fail('invalid_name', 'Informe o nome completo.'); end if;
  if v_phone !~ '^[0-9]{10,13}$' then perform app.fail('invalid_phone', 'Informe um telefone com DDD.'); end if;
  if length(btrim(coalesce(p_terms_version, ''))) = 0 then
    perform app.fail('terms_required', 'É preciso aceitar os termos de uso e a política de privacidade.');
  end if;
  insert into public.profiles (id, full_name, phone, role, terms_version, terms_accepted_at)
  values (v_uid, btrim(p_full_name), v_phone, p_role::public.user_role, btrim(p_terms_version), now());
  if p_role = 'provider' then insert into public.providers (id) values (v_uid); end if;
end $$;

-- =============================================================================
-- Cliente
-- =============================================================================
create function public.list_services() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select case when auth.uid() is null then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'code', code, 'name', name, 'description', description,
    'base_price', base_price, 'est_minutes', est_minutes) order by sort, name), '[]'::jsonb) end
  from public.services where active
$$;

create function public.list_vehicles() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('customer');
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'plate', plate, 'brand', brand, 'model', model, 'year', year)
    order by created_at) from public.vehicles where customer_id = v_uid and not archived), '[]'::jsonb);
end $$;

create function public.save_vehicle(p_plate text, p_brand text, p_model text, p_year integer) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('customer');
  v_plate text := upper(regexp_replace(coalesce(p_plate, ''), '[^A-Za-z0-9]', '', 'g'));
  v_id uuid;
begin
  if v_plate !~ '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$' then
    perform app.fail('invalid_plate', 'Placa inválida. Use o formato ABC1D23 ou ABC1234.');
  end if;
  if exists (select 1 from public.vehicles where customer_id = v_uid and plate = v_plate and not archived) then
    perform app.fail('vehicle_exists', 'Este veículo já está cadastrado.');
  end if;
  insert into public.vehicles (customer_id, plate, brand, model, year)
  values (v_uid, v_plate, btrim(p_brand), btrim(p_model), p_year) returning id into v_id;
  return v_id;
end $$;

create function public.archive_vehicle(p_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('customer');
begin
  update public.vehicles set archived = true where id = p_id and customer_id = v_uid;
  if not found then perform app.deny(); end if;
end $$;

create function public.create_request(
  p_service_id uuid, p_vehicle_id uuid, p_address text,
  p_lat double precision default null, p_lng double precision default null, p_notes text default ''
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('customer');
  v_price numeric(12,2);
  v_pct numeric(5,2);
  v_commission numeric(12,2);
  v_id uuid;
begin
  select base_price into v_price from public.services where id = p_service_id and active;
  if v_price is null then perform app.fail('service_unavailable', 'Este serviço não está disponível.'); end if;
  if not exists (select 1 from public.vehicles where id = p_vehicle_id and customer_id = v_uid and not archived) then
    perform app.fail('vehicle_not_found', 'Escolha um dos seus veículos.');
  end if;
  if length(btrim(coalesce(p_address, ''))) < 5 then perform app.fail('invalid_address', 'Informe o endereço do atendimento.'); end if;
  if (select count(*) from public.requests where customer_id = v_uid and status not in ('completed', 'cancelled')) >= 3 then
    perform app.fail('too_many_requests', 'Você já tem pedidos em andamento. Conclua ou cancele um deles.');
  end if;
  if exists (select 1 from public.requests where customer_id = v_uid and status = 'completed' and payment_status = 'pending') then
    perform app.fail('payment_pending', 'Há um atendimento concluído aguardando pagamento.');
  end if;
  select commission_percent into v_pct from public.settings;
  v_commission := round(v_price * v_pct / 100, 2);
  insert into public.requests (customer_id, vehicle_id, service_id, address, lat, lng, notes,
    price, commission_percent, total, commission_amount, provider_net)
  values (v_uid, p_vehicle_id, p_service_id, btrim(p_address), p_lat, p_lng, left(btrim(coalesce(p_notes, '')), 500),
    v_price, v_pct, v_price, v_commission, v_price - v_commission)
  returning id into v_id;
  perform app.log(v_id, 'created', 'customer');
  return v_id;
end $$;

create function public.my_requests() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('customer');
begin
  return coalesce((select jsonb_agg(app.request_json(r.id, 'full') order by r.created_at desc)
    from (select id, created_at from public.requests where customer_id = v_uid order by created_at desc limit 50) r), '[]'::jsonb);
end $$;

-- Detalhe do pedido para quem tem relação com ele: o cliente, o prestador que
-- aceitou, um prestador a quem o pedido está sendo oferecido, ou a HUB.
create function public.request_detail(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid uuid := app.uid();
  v_role public.user_role;
  r public.requests;
  p public.providers;
begin
  select role into v_role from public.profiles where id = v_uid;
  select * into r from public.requests where id = p_id;
  if r.id is null or v_role is null then perform app.deny(); end if;
  if v_role = 'hub_admin' or r.customer_id = v_uid then return app.request_json(p_id, 'full'); end if;
  if r.provider_id = v_uid then
    select * into p from public.providers where id = v_uid;
    return app.request_json(p_id, 'full', p.last_lat, p.last_lng);
  end if;
  if v_role = 'provider' and r.status = 'searching' and app.can_take(v_uid, p_id) then
    select * into p from public.providers where id = v_uid;
    return app.request_json(p_id, 'offer', coalesce(p.last_lat, p.base_lat), coalesce(p.last_lng, p.base_lng));
  end if;
  perform app.deny();
  return null;
end $$;

create function public.cancel_request(p_id uuid, p_reason text default '') returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('customer');
begin
  update public.requests set status = 'cancelled', cancelled_at = now(), cancelled_by = 'customer',
    cancel_reason = left(btrim(coalesce(p_reason, '')), 300)
  where id = p_id and customer_id = v_uid and status in ('searching', 'accepted', 'en_route');
  if not found then perform app.fail('cannot_cancel', 'Este pedido não pode mais ser cancelado pelo aplicativo. Fale com o suporte.'); end if;
  perform app.log(p_id, 'cancelled', 'customer', nullif(btrim(coalesce(p_reason, '')), ''));
end $$;

create function public.decide_extra(p_extra_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('customer');
  v_request uuid;
begin
  update public.request_extras e set status = case when p_approve then 'approved' else 'rejected' end::public.extra_status, decided_at = now()
  from public.requests r
  where e.id = p_extra_id and r.id = e.request_id and r.customer_id = v_uid
    and r.status = 'in_progress' and e.status = 'proposed'
  returning r.id into v_request;
  if v_request is null then perform app.fail('extra_closed', 'Este orçamento não está mais aguardando resposta.'); end if;
  perform app.recalc(v_request);
  perform app.log(v_request, case when p_approve then 'extra_approved' else 'extra_rejected' end, 'customer');
end $$;

-- Como o cliente paga. Sem chave Pix cadastrada pela HUB, o aplicativo fica em
-- modo demonstração e o pagamento é simulado. A integração com um provedor de
-- pagamentos (Pix com divisão automática) substitui estas três funções.
create function public.payment_info() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'mode', case when s.pix_key is null then 'demo' else 'pix' end,
    'pix_key', s.pix_key, 'pix_holder', s.pix_holder) end
  from public.settings s
$$;

create function app.mark_paid(p_id uuid, p_actor public.user_role) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_days integer;
begin
  select payout_days into v_days from public.settings;
  update public.requests set payment_status = 'paid', paid_at = now(), payout_status = 'pending',
    payout_due = (now() + make_interval(days => v_days))::date
  where id = p_id and status = 'completed' and payment_status = 'pending';
  if not found then perform app.fail('cannot_pay', 'Este pedido não está aguardando pagamento.'); end if;
  perform app.log(p_id, 'paid', p_actor);
end $$;

-- Modo demonstração: o próprio cliente confirma e nada é cobrado.
create function public.pay_request(p_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('customer');
begin
  if (select pix_key from public.settings) is not null then
    perform app.fail('pix_required', 'O pagamento deste pedido é por Pix.');
  end if;
  if not exists (select 1 from public.requests where id = p_id and customer_id = v_uid) then perform app.deny(); end if;
  perform app.mark_paid(p_id, 'customer');
end $$;

-- Pix: o cliente avisa que pagou; quem confirma o recebimento é a HUB.
create function public.claim_payment(p_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('customer');
begin
  if (select pix_key from public.settings) is null then perform app.fail('demo_mode', 'O pagamento por Pix não está habilitado.'); end if;
  update public.requests set payment_claimed_at = now()
  where id = p_id and customer_id = v_uid and status = 'completed' and payment_status = 'pending' and payment_claimed_at is null;
  if not found then perform app.fail('cannot_pay', 'Este pedido não está aguardando pagamento.'); end if;
  perform app.log(p_id, 'payment_claimed', 'customer');
end $$;

create function public.review_request(p_id uuid, p_rating integer, p_comment text default '') returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('customer');
  v_provider uuid;
begin
  if p_rating is null or p_rating not between 1 and 5 then perform app.fail('invalid_rating', 'Escolha de 1 a 5 estrelas.'); end if;
  select provider_id into v_provider from public.requests where id = p_id and customer_id = v_uid and status = 'completed';
  if v_provider is null then perform app.fail('cannot_review', 'Só é possível avaliar atendimentos concluídos.'); end if;
  if exists (select 1 from public.reviews where request_id = p_id) then perform app.fail('already_reviewed', 'Você já avaliou este atendimento.'); end if;
  insert into public.reviews (request_id, provider_id, rating, comment) values (p_id, v_provider, p_rating, left(btrim(coalesce(p_comment, '')), 500));
end $$;

-- =============================================================================
-- Prestador
-- =============================================================================

-- O pedido pode ser oferecido a este prestador? Credenciado, com contrato
-- vigente aceito, habilitado no serviço, dentro do raio e sem tê-lo recusado.
create function app.can_take(p_provider uuid, p_request uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.requests r
    join public.providers p on p.id = p_provider
    join public.provider_services ps on ps.provider_id = p.id and ps.service_id = r.service_id and ps.status = 'approved'
    where r.id = p_request and r.status = 'searching' and r.customer_id <> p.id
      and p.status = 'approved' and app.contract_ok(p.id)
      and not exists (select 1 from public.request_declines d where d.request_id = r.id and d.provider_id = p.id)
      and coalesce(app.km(coalesce(p.last_lat, p.base_lat), coalesce(p.last_lng, p.base_lng), r.lat, r.lng), 0)
          <= least(p.radius_km, (select search_radius_km from public.settings)))
$$;

create function public.provider_apply(
  p_doc_type text, p_doc_number text, p_legal_name text, p_city text, p_experience text,
  p_radius_km integer, p_service_ids uuid[], p_lat double precision default null, p_lng double precision default null
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('provider');
  v_doc text := regexp_replace(coalesce(p_doc_number, ''), '[^0-9]', '', 'g');
  v_status public.provider_status;
begin
  select status into v_status from public.providers where id = v_uid;
  if v_status not in ('draft', 'rejected', 'closed') then
    perform app.fail('already_applied', 'Seu credenciamento já foi enviado.');
  end if;
  if p_doc_type not in ('cpf', 'cnpj') or (p_doc_type = 'cpf' and length(v_doc) <> 11) or (p_doc_type = 'cnpj' and length(v_doc) <> 14) then
    perform app.fail('invalid_doc', 'Confira o CPF ou CNPJ informado.');
  end if;
  if length(btrim(coalesce(p_legal_name, ''))) < 3 then perform app.fail('invalid_name', 'Informe o nome ou a razão social.'); end if;
  if length(btrim(coalesce(p_city, ''))) < 2 then perform app.fail('invalid_city', 'Informe a cidade de atuação.'); end if;
  if coalesce(p_radius_km, 0) not between 1 and 200 then perform app.fail('invalid_radius', 'Informe um raio de atendimento entre 1 e 200 km.'); end if;
  if coalesce(array_length(p_service_ids, 1), 0) = 0 then perform app.fail('no_services', 'Escolha ao menos um serviço.'); end if;
  if not exists (select 1 from public.provider_documents where provider_id = v_uid and kind = 'identity') then
    perform app.fail('identity_required', 'Envie ao menos um documento de identificação antes de concluir.');
  end if;
  if exists (select 1 from unnest(p_service_ids) s where not exists (select 1 from public.services where id = s and active)) then
    perform app.fail('service_unavailable', 'Um dos serviços escolhidos não está disponível.');
  end if;
  update public.providers set status = 'pending', doc_type = p_doc_type, doc_number = v_doc,
    legal_name = btrim(p_legal_name), city = btrim(p_city), experience = left(btrim(coalesce(p_experience, '')), 1000),
    radius_km = p_radius_km, base_lat = p_lat, base_lng = p_lng, applied_at = now(), decided_at = null, review_note = null, online = false
  where id = v_uid;
  delete from public.provider_services where provider_id = v_uid and status <> 'approved';
  insert into public.provider_services (provider_id, service_id)
  select v_uid, s from unnest(p_service_ids) s on conflict do nothing;
end $$;

create function public.provider_home() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('provider');
  p public.providers;
begin
  select * into p from public.providers where id = v_uid;
  return jsonb_build_object(
    'status', p.status, 'online', p.online, 'city', p.city, 'radius_km', p.radius_km,
    'doc_type', p.doc_type, 'legal_name', p.legal_name, 'review_note', p.review_note,
    'has_position', coalesce(p.last_lat, p.base_lat) is not null,
    'contract_ok', app.contract_ok(v_uid),
    'rating', app.rating(v_uid),
    'services', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'status', ps.status) order by s.sort, s.name)
      from public.provider_services ps join public.services s on s.id = ps.service_id where ps.provider_id = v_uid), '[]'::jsonb),
    'suspension', (select jsonb_build_object('id', id, 'reason', reason, 'precautionary', precautionary,
        'created_at', created_at, 'contest_text', contest_text, 'contested_at', contested_at)
      from public.suspensions where provider_id = v_uid and resolved_at is null),
    'active_request', (select id from public.requests where provider_id = v_uid and status in ('accepted', 'en_route', 'in_progress')));
end $$;

create function public.current_contract() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := app.uid();
begin
  if not exists (select 1 from public.profiles where id = v_uid and role in ('provider', 'hub_admin')) then perform app.deny(); end if;
  return (select jsonb_build_object('id', v.id, 'version', v.version, 'title', v.title, 'body', v.body,
      'body_sha256', v.body_sha256, 'published_at', v.published_at,
      'commission_percent', s.commission_percent, 'payout_days', s.payout_days,
      'acceptance', (select jsonb_build_object('accepted_at', a.accepted_at, 'signer_name', a.signer_name,
          'commission_percent', a.commission_percent, 'payout_days', a.payout_days)
        from public.contract_acceptances a where a.contract_version_id = v.id and a.provider_id = v_uid))
    from public.contract_versions v, public.settings s where v.is_current);
end $$;

-- Aceite eletrônico. O IP e o navegador são informados pelo servidor do
-- aplicativo, nunca pelo navegador do usuário.
create function public.accept_contract(p_version_id uuid, p_ip text, p_user_agent text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('provider');
  p public.providers;
  v public.contract_versions;
  s public.settings;
begin
  select * into p from public.providers where id = v_uid;
  if p.status in ('draft', 'rejected', 'closed') or p.doc_number is null then
    perform app.fail('apply_first', 'Envie primeiro os dados do credenciamento.');
  end if;
  select * into v from public.contract_versions where id = p_version_id and is_current;
  if v.id is null then perform app.fail('contract_outdated', 'Esta versão do contrato não está mais vigente. Recarregue a página.'); end if;
  select * into s from public.settings;
  insert into public.contract_acceptances (provider_id, contract_version_id, signer_name, signer_doc, body_sha256,
    commission_percent, payout_days, ip, user_agent)
  values (v_uid, v.id, p.legal_name, p.doc_number, v.body_sha256, s.commission_percent, s.payout_days,
    left(p_ip, 64), left(p_user_agent, 300))
  on conflict (provider_id, contract_version_id) do nothing;
end $$;

-- Ficar disponível ou indisponível é decisão do prestador, a qualquer momento.
create function public.set_online(p_online boolean, p_lat double precision default null, p_lng double precision default null) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('provider');
  p public.providers;
begin
  select * into p from public.providers where id = v_uid;
  if p_online then
    if p.status <> 'approved' then perform app.fail('not_approved', 'Seu credenciamento ainda não está ativo.'); end if;
    if not app.contract_ok(v_uid) then perform app.fail('contract_required', 'Aceite a versão vigente do contrato para receber pedidos.'); end if;
  end if;
  update public.providers set online = p_online,
    last_lat = coalesce(p_lat, last_lat), last_lng = coalesce(p_lng, last_lng), last_seen_at = now()
  where id = v_uid;
end $$;

create function public.update_position(p_lat double precision, p_lng double precision) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('provider');
begin
  -- Localização só é guardada com o prestador disponível ou em atendimento (12.4).
  update public.providers set last_lat = p_lat, last_lng = p_lng, last_seen_at = now()
  where id = v_uid and (online or exists (select 1 from public.requests
    where provider_id = v_uid and status in ('accepted', 'en_route', 'in_progress')));
end $$;

create function public.open_requests() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('provider');
  p public.providers;
begin
  select * into p from public.providers where id = v_uid;
  if not p.online then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(app.request_json(r.id, 'offer', coalesce(p.last_lat, p.base_lat), coalesce(p.last_lng, p.base_lng)) order by r.created_at)
    from public.requests r where r.status = 'searching' and app.can_take(v_uid, r.id)), '[]'::jsonb);
end $$;

create function public.accept_request(p_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('provider');
begin
  if not (select online from public.providers where id = v_uid) then
    perform app.fail('offline', 'Fique disponível para aceitar pedidos.');
  end if;
  if exists (select 1 from public.requests where provider_id = v_uid and status in ('accepted', 'en_route', 'in_progress')) then
    perform app.fail('busy', 'Conclua o atendimento em andamento antes de aceitar outro.');
  end if;
  if not app.can_take(v_uid, p_id) then perform app.fail('request_taken', 'Este pedido não está mais disponível.'); end if;
  -- A condição no UPDATE garante que só um prestador fica com o pedido.
  update public.requests set status = 'accepted', provider_id = v_uid, accepted_at = now()
  where id = p_id and status = 'searching';
  if not found then perform app.fail('request_taken', 'Este pedido não está mais disponível.'); end if;
  perform app.log(p_id, 'accepted', 'provider');
end $$;

-- Recusar não gera punição nem afeta a classificação: só tira o pedido da lista.
create function public.decline_request(p_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('provider');
begin
  if not exists (select 1 from public.requests where id = p_id and status = 'searching') then return; end if;
  insert into public.request_declines (request_id, provider_id) values (p_id, v_uid) on conflict do nothing;
end $$;

create function public.advance_request(p_id uuid, p_to text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('provider');
  v_from public.request_status;
begin
  select status into v_from from public.requests where id = p_id and provider_id = v_uid for update;
  if v_from is null then perform app.deny(); end if;
  if not ((v_from = 'accepted' and p_to = 'en_route') or (v_from = 'en_route' and p_to = 'in_progress')
       or (v_from = 'in_progress' and p_to = 'completed')) then
    perform app.fail('invalid_step', 'Esta etapa não está disponível agora.');
  end if;
  if p_to = 'completed' and exists (select 1 from public.request_extras where request_id = p_id and status = 'proposed') then
    perform app.fail('extras_pending', 'Há um orçamento adicional aguardando a resposta do cliente.');
  end if;
  update public.requests set status = p_to::public.request_status,
    started_at = case when p_to = 'in_progress' then now() else started_at end,
    completed_at = case when p_to = 'completed' then now() else completed_at end
  where id = p_id;
  perform app.log(p_id, p_to, 'provider');
end $$;

-- Desistência justificada depois do aceite: o pedido volta para a busca.
create function public.withdraw_request(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('provider');
begin
  if length(btrim(coalesce(p_reason, ''))) < 10 then perform app.fail('reason_required', 'Explique o motivo (ao menos 10 caracteres).'); end if;
  update public.requests set status = 'searching', provider_id = null, accepted_at = null
  where id = p_id and provider_id = v_uid and status in ('accepted', 'en_route');
  if not found then perform app.fail('cannot_withdraw', 'Não é possível desistir depois de iniciar o serviço. Fale com o suporte.'); end if;
  insert into public.request_declines (request_id, provider_id) values (p_id, v_uid) on conflict do nothing;
  perform app.log(p_id, 'withdrawn', 'provider', left(btrim(p_reason), 300));
end $$;

create function public.propose_extra(p_id uuid, p_description text, p_price numeric) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('provider');
  v_id uuid;
begin
  if not exists (select 1 from public.requests where id = p_id and provider_id = v_uid and status = 'in_progress') then
    perform app.fail('not_in_progress', 'Orçamentos adicionais só podem ser enviados durante o serviço.');
  end if;
  if length(btrim(coalesce(p_description, ''))) < 3 then perform app.fail('invalid_description', 'Descreva o serviço adicional.'); end if;
  if p_price is null or p_price <= 0 or p_price > 50000 then perform app.fail('invalid_price', 'Informe um valor válido.'); end if;
  insert into public.request_extras (request_id, description, price) values (p_id, btrim(p_description), round(p_price, 2)) returning id into v_id;
  perform app.log(p_id, 'extra_proposed', 'provider', btrim(p_description));
  return v_id;
end $$;

create function public.provider_jobs() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('provider');
begin
  return jsonb_build_object(
    'summary', (select jsonb_build_object(
        'completed', count(*) filter (where status = 'completed'),
        'net_total', coalesce(sum(provider_net) filter (where status = 'completed'), 0),
        'to_receive', coalesce(sum(provider_net) filter (where payout_status = 'pending'), 0),
        'received', coalesce(sum(provider_net) filter (where payout_status = 'paid'), 0),
        'awaiting_payment', coalesce(sum(provider_net) filter (where status = 'completed' and payment_status = 'pending'), 0))
      from public.requests where provider_id = v_uid),
    'jobs', coalesce((select jsonb_agg(app.request_json(r.id, 'full') order by r.created_at desc)
      from (select id, created_at from public.requests where provider_id = v_uid order by created_at desc limit 50) r), '[]'::jsonb));
end $$;

create function public.contest_suspension(p_id uuid, p_text text) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('provider');
begin
  if length(btrim(coalesce(p_text, ''))) < 20 then perform app.fail('text_required', 'Explique sua contestação (ao menos 20 caracteres).'); end if;
  update public.suspensions set contest_text = left(btrim(p_text), 2000), contested_at = now()
  where id = p_id and provider_id = v_uid and resolved_at is null and contested_at is null;
  if not found then perform app.fail('cannot_contest', 'Esta suspensão já foi contestada ou revista.'); end if;
end $$;

-- Encerramento a pedido do prestador, respeitados os atendimentos assumidos (14.2).
create function public.close_credentialing() returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('provider');
begin
  if exists (select 1 from public.requests where provider_id = v_uid and status in ('accepted', 'en_route', 'in_progress')) then
    perform app.fail('active_job', 'Conclua o atendimento em andamento antes de encerrar o credenciamento.');
  end if;
  update public.providers set status = 'closed', online = false, decided_at = now()
  where id = v_uid and status in ('pending', 'approved');
  if not found then perform app.fail('cannot_close', 'Seu credenciamento não está ativo.'); end if;
end $$;

-- =============================================================================
-- HUB (administração)
-- =============================================================================
create function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  return jsonb_build_object(
    'providers', (select jsonb_build_object(
        'pending', count(*) filter (where status = 'pending'),
        'approved', count(*) filter (where status = 'approved'),
        'online', count(*) filter (where status = 'approved' and online),
        'suspended', count(*) filter (where status = 'suspended')) from public.providers),
    'contests', (select count(*) from public.suspensions where resolved_at is null and contested_at is not null),
    'customers', (select count(*) from public.profiles where role = 'customer'),
    'requests', (select jsonb_build_object(
        'searching', count(*) filter (where status = 'searching'),
        'active', count(*) filter (where status in ('accepted', 'en_route', 'in_progress')),
        'completed', count(*) filter (where status = 'completed'),
        'cancelled', count(*) filter (where status = 'cancelled'),
        'gross', coalesce(sum(total) filter (where payment_status = 'paid'), 0),
        'commission', coalesce(sum(commission_amount) filter (where payment_status = 'paid'), 0),
        'payouts_pending', coalesce(sum(provider_net) filter (where payout_status = 'pending'), 0),
        'awaiting_payment', coalesce(sum(total) filter (where status = 'completed' and payment_status = 'pending'), 0))
      from public.requests),
    'rating', (select jsonb_build_object('average', round(avg(rating)::numeric, 1), 'count', count(*)) from public.reviews),
    'payments_to_confirm', (select count(*) from public.requests where payment_status = 'pending' and payment_claimed_at is not null),
    'settings', (select jsonb_build_object('commission_percent', s.commission_percent, 'payout_days', s.payout_days,
        'search_radius_km', s.search_radius_km, 'pix_key', s.pix_key, 'pix_holder', s.pix_holder,
        'setup_code_pending', s.setup_code_hash is not null) from public.settings s),
    'contract', (select jsonb_build_object('version', version, 'title', title) from public.contract_versions where is_current));
end $$;

create function public.admin_providers() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', pf.full_name, 'legal_name', p.legal_name, 'city', p.city, 'status', p.status,
      'online', p.online, 'applied_at', p.applied_at, 'contract_ok', app.contract_ok(p.id), 'rating', app.rating(p.id),
      'completed', (select count(*) from public.requests r where r.provider_id = p.id and r.status = 'completed'),
      'contested', exists (select 1 from public.suspensions s where s.provider_id = p.id and s.resolved_at is null and s.contested_at is not null))
    order by (p.status = 'pending') desc, p.applied_at desc nulls last)
    from public.providers p join public.profiles pf on pf.id = p.id where p.status <> 'draft'), '[]'::jsonb);
end $$;

create function public.admin_provider(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  return (select jsonb_build_object(
      'id', p.id, 'name', pf.full_name, 'phone', pf.phone, 'status', p.status, 'online', p.online,
      'doc_type', p.doc_type, 'doc_number', p.doc_number, 'legal_name', p.legal_name, 'city', p.city,
      'experience', p.experience, 'radius_km', p.radius_km, 'review_note', p.review_note,
      'applied_at', p.applied_at, 'decided_at', p.decided_at, 'rating', app.rating(p.id),
      'completed', (select count(*) from public.requests r where r.provider_id = p.id and r.status = 'completed'),
      'services', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'status', ps.status) order by s.sort, s.name)
        from public.provider_services ps join public.services s on s.id = ps.service_id where ps.provider_id = p.id), '[]'::jsonb),
      'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'file_name', d.file_name,
          'mime', d.mime, 'size', d.size, 'created_at', d.created_at) order by d.created_at)
        from public.provider_documents d where d.provider_id = p.id), '[]'::jsonb),
      'acceptances', coalesce((select jsonb_agg(jsonb_build_object('version', v.version, 'accepted_at', a.accepted_at,
          'signer_name', a.signer_name, 'ip', a.ip, 'body_sha256', a.body_sha256,
          'commission_percent', a.commission_percent, 'payout_days', a.payout_days, 'current', v.is_current) order by a.accepted_at desc)
        from public.contract_acceptances a join public.contract_versions v on v.id = a.contract_version_id where a.provider_id = p.id), '[]'::jsonb),
      'suspensions', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'reason', s.reason, 'precautionary', s.precautionary,
          'created_at', s.created_at, 'contest_text', s.contest_text, 'contested_at', s.contested_at,
          'resolution', s.resolution, 'resolution_note', s.resolution_note, 'resolved_at', s.resolved_at) order by s.created_at desc)
        from public.suspensions s where s.provider_id = p.id), '[]'::jsonb))
    from public.providers p join public.profiles pf on pf.id = p.id where p.id = p_id);
end $$;

-- Decisão do credenciamento, serviço a serviço (cláusula 4).
create function public.admin_decide_provider(p_id uuid, p_approved_service_ids uuid[], p_note text default '') returns void
language plpgsql security definer set search_path = ''
as $$
declare v_approve boolean := coalesce(array_length(p_approved_service_ids, 1), 0) > 0;
begin
  perform app.require_role('hub_admin');
  if not v_approve and length(btrim(coalesce(p_note, ''))) < 10 then
    perform app.fail('note_required', 'Ao recusar, informe o motivo ao prestador (ao menos 10 caracteres).');
  end if;
  update public.providers set status = case when v_approve then 'approved' else 'rejected' end::public.provider_status,
    decided_at = now(), review_note = nullif(btrim(coalesce(p_note, '')), ''), online = false
  where id = p_id and status in ('pending', 'approved');
  if not found then perform app.fail('not_pending', 'Este credenciamento não está aguardando análise.'); end if;
  update public.provider_services set decided_at = now(),
    status = case when service_id = any (coalesce(p_approved_service_ids, '{}')) then 'approved' else 'rejected' end::public.qualification_status
  where provider_id = p_id;
end $$;

-- Suspensão: sempre com motivo objetivo registrado e comunicado (cláusula 11).
create function public.admin_suspend_provider(p_id uuid, p_reason text, p_precautionary boolean default false) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('hub_admin');
begin
  if length(btrim(coalesce(p_reason, ''))) < 10 then perform app.fail('reason_required', 'Descreva o motivo objetivo da suspensão.'); end if;
  update public.providers set status = 'suspended', online = false where id = p_id and status = 'approved';
  if not found then perform app.fail('not_approved', 'Só é possível suspender um credenciamento ativo.'); end if;
  insert into public.suspensions (provider_id, reason, precautionary, created_by) values (p_id, btrim(p_reason), coalesce(p_precautionary, false), v_uid);
end $$;

create function public.admin_resolve_suspension(p_id uuid, p_lift boolean, p_note text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('hub_admin');
  v_provider uuid;
begin
  if length(btrim(coalesce(p_note, ''))) < 10 then perform app.fail('note_required', 'Registre a fundamentação da decisão.'); end if;
  update public.suspensions set resolution = case when p_lift then 'lifted' else 'upheld' end,
    resolution_note = btrim(p_note), resolved_by = v_uid, resolved_at = now()
  where id = p_id and resolved_at is null returning provider_id into v_provider;
  if v_provider is null then perform app.fail('already_resolved', 'Esta suspensão já foi revista.'); end if;
  if p_lift then update public.providers set status = 'approved' where id = v_provider and status = 'suspended'; end if;
end $$;

create function public.admin_requests() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  return coalesce((select jsonb_agg(app.request_json(r.id, 'full') order by r.created_at desc)
    from (select id, created_at from public.requests order by created_at desc limit 100) r), '[]'::jsonb);
end $$;

create function public.admin_mark_payout(p_request_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  update public.requests set payout_status = 'paid', payout_at = now() where id = p_request_id and payout_status = 'pending';
  if not found then perform app.fail('no_payout', 'Não há repasse pendente para este pedido.'); end if;
  perform app.log(p_request_id, 'payout', 'hub_admin');
end $$;

create function public.admin_confirm_payment(p_request_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  perform app.mark_paid(p_request_id, 'hub_admin');
end $$;

-- Chave Pix da HUB. Em branco, o aplicativo volta ao modo demonstração.
create function public.admin_save_pix(p_pix_key text, p_pix_holder text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_key text := nullif(btrim(coalesce(p_pix_key, '')), '');
  v_holder text := nullif(btrim(coalesce(p_pix_holder, '')), '');
begin
  perform app.require_role('hub_admin');
  if v_key is not null and (length(v_key) < 5 or v_holder is null or length(v_holder) < 3) then
    perform app.fail('invalid_pix', 'Informe a chave Pix e o nome do titular que aparece no comprovante.');
  end if;
  update public.settings set pix_key = v_key, pix_holder = case when v_key is null then null else v_holder end, updated_at = now();
end $$;

create function public.admin_save_settings(p_commission_percent numeric, p_payout_days integer, p_search_radius_km integer) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  if p_commission_percent is null or p_commission_percent not between 0 and 60 then perform app.fail('invalid_commission', 'A comissão deve ficar entre 0% e 60%.'); end if;
  if p_payout_days is null or p_payout_days not between 0 and 60 then perform app.fail('invalid_payout', 'O prazo de repasse deve ficar entre 0 e 60 dias.'); end if;
  if p_search_radius_km is null or p_search_radius_km not between 1 and 200 then perform app.fail('invalid_radius', 'O raio deve ficar entre 1 e 200 km.'); end if;
  -- Vale para pedidos novos; os já criados mantêm a comissão informada ao prestador.
  update public.settings set commission_percent = p_commission_percent, payout_days = p_payout_days,
    search_radius_km = p_search_radius_km, updated_at = now();
end $$;

create function public.admin_services() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  return coalesce((select jsonb_agg(to_jsonb(s) order by s.sort, s.name) from public.services s), '[]'::jsonb);
end $$;

create function public.admin_save_service(p_id uuid, p_name text, p_description text, p_base_price numeric, p_est_minutes integer, p_active boolean) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  if length(btrim(coalesce(p_name, ''))) < 3 then perform app.fail('invalid_name', 'Informe o nome do serviço.'); end if;
  if p_base_price is null or p_base_price <= 0 then perform app.fail('invalid_price', 'Informe um preço válido.'); end if;
  if p_est_minutes is null or p_est_minutes not between 5 and 600 then perform app.fail('invalid_minutes', 'Informe a duração entre 5 e 600 minutos.'); end if;
  if p_id is null then
    insert into public.services (code, name, description, base_price, est_minutes, active, sort)
    values ('servico_' || translate(left(gen_random_uuid()::text, 8), '0123456789-', 'abcdefghij_'), btrim(p_name),
      btrim(coalesce(p_description, '')), round(p_base_price, 2), p_est_minutes, coalesce(p_active, true),
      (select coalesce(max(sort), 0) + 10 from public.services));
  else
    update public.services set name = btrim(p_name), description = btrim(coalesce(p_description, '')),
      base_price = round(p_base_price, 2), est_minutes = p_est_minutes, active = coalesce(p_active, true) where id = p_id;
    if not found then perform app.fail('not_found', 'Serviço não encontrado.'); end if;
  end if;
end $$;

-- Só com a chave secreta (fora do aplicativo): promove uma conta a administrador da HUB.
create function public.promote_hub_admin(p_email text, p_full_name text, p_phone text) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  if coalesce(auth.role(), '') <> 'service_role' then perform app.deny(); end if;
  select id into v_id from auth.users where email = lower(p_email);
  if v_id is null then perform app.fail('user_not_found', 'Crie primeiro a conta com este e-mail.'); end if;
  if exists (select 1 from public.providers where id = v_id) then perform app.fail('is_provider', 'Esta conta é de prestador.'); end if;
  insert into public.profiles (id, full_name, phone, role) values (v_id, p_full_name, p_phone, 'hub_admin')
  on conflict (id) do update set role = 'hub_admin';
end $$;

-- >>> 20261116000300_functions_account.sql
-- =============================================================================
-- Zé do Carro — 03 Conta, avisos, documentos e privilégios
-- =============================================================================

create function app.brl(p numeric) returns text
language sql immutable set search_path = ''
as $$ select 'R$ ' || replace(to_char(p, 'FM999999990.00'), '.', ',') $$;

-- -----------------------------------------------------------------------------
-- Conta
-- -----------------------------------------------------------------------------
create function public.update_profile(p_full_name text, p_phone text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.uid();
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
begin
  if length(btrim(coalesce(p_full_name, ''))) < 3 then perform app.fail('invalid_name', 'Informe o nome completo.'); end if;
  if v_phone !~ '^[0-9]{10,13}$' then perform app.fail('invalid_phone', 'Informe um telefone com DDD.'); end if;
  update public.profiles set full_name = btrim(p_full_name), phone = v_phone where id = v_uid;
  if not found then perform app.deny(); end if;
end $$;

-- Acesso da equipe da HUB: a conta recém-criada (ainda sem cadastro) informa um
-- código de ativação de uso único. O banco guarda só o hash do código.
create function public.claim_hub_admin(p_code text, p_full_name text, p_phone text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.uid();
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_hash text := encode(extensions.digest(upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')), 'sha256'), 'hex');
begin
  if exists (select 1 from public.profiles where id = v_uid) then perform app.fail('profile_exists', 'Esta conta já tem cadastro.'); end if;
  if length(btrim(coalesce(p_full_name, ''))) < 3 then perform app.fail('invalid_name', 'Informe o nome completo.'); end if;
  if v_phone !~ '^[0-9]{10,13}$' then perform app.fail('invalid_phone', 'Informe um telefone com DDD.'); end if;
  update public.settings set setup_code_hash = null where setup_code_hash = v_hash;
  if not found then perform app.fail('invalid_code', 'Código de ativação inválido ou já utilizado.'); end if;
  insert into public.profiles (id, full_name, phone, role) values (v_uid, btrim(p_full_name), v_phone, 'hub_admin');
end $$;

-- Gera um novo código de ativação (substitui o anterior). Aparece uma única vez.
create function public.admin_new_setup_code() returns text
language plpgsql security definer set search_path = ''
as $$
declare v_code text := upper(encode(extensions.gen_random_bytes(10), 'hex'));
begin
  perform app.require_role('hub_admin');
  update public.settings set setup_code_hash = encode(extensions.digest(v_code, 'sha256'), 'hex');
  return v_code;
end $$;

-- Limite de tentativas. Só o servidor do aplicativo (chave secreta) chama.
create function public.check_rate_limit(p_key text, p_max integer, p_window_seconds integer, p_increment boolean) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare v_count integer;
begin
  if coalesce(auth.role(), '') <> 'service_role' then perform app.deny(); end if;
  delete from public.rate_limits where key = p_key and window_start < now() - make_interval(secs => p_window_seconds);
  if p_increment then
    insert into public.rate_limits (key, count) values (p_key, 1)
    on conflict (key) do update set count = public.rate_limits.count + 1
    returning count into v_count;
    return v_count <= p_max;
  end if;
  select count into v_count from public.rate_limits where key = p_key;
  return coalesce(v_count, 0) < p_max;
end $$;

create function public.clear_rate_limit(p_key text) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then perform app.deny(); end if;
  delete from public.rate_limits where key = p_key;
end $$;

-- -----------------------------------------------------------------------------
-- Documentos do credenciamento
-- -----------------------------------------------------------------------------
create function public.upload_document(p_kind text, p_file_name text, p_mime text, p_content_base64 text) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('provider');
  v_content bytea;
  v_id uuid;
begin
  if p_kind not in ('identity', 'address', 'certificate', 'equipment', 'other') then perform app.fail('invalid_kind', 'Escolha o tipo do documento.'); end if;
  if p_mime not in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf') then
    perform app.fail('invalid_file', 'Envie uma foto (JPG, PNG ou WebP) ou um PDF.');
  end if;
  if (select status from public.providers where id = v_uid) = 'closed' then perform app.fail('closed', 'Seu credenciamento está encerrado.'); end if;
  if (select count(*) from public.provider_documents where provider_id = v_uid) >= 12 then
    perform app.fail('too_many_documents', 'Limite de 12 documentos. Remova algum para enviar outro.');
  end if;
  begin
    v_content := decode(p_content_base64, 'base64');
  exception when others then
    perform app.fail('invalid_file', 'Não foi possível ler o arquivo. Tente de novo.');
  end;
  if length(v_content) = 0 or length(v_content) > 3145728 then perform app.fail('file_too_large', 'O arquivo precisa ter até 3 MB.'); end if;
  insert into public.provider_documents (provider_id, kind, file_name, mime, size, content)
  values (v_uid, p_kind, left(regexp_replace(coalesce(nullif(btrim(p_file_name), ''), 'documento'), '[^A-Za-z0-9À-ÿ._ -]', '_', 'g'), 120),
    p_mime, length(v_content), v_content)
  returning id into v_id;
  return v_id;
end $$;

create function public.my_documents() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('provider');
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'file_name', file_name, 'mime', mime,
      'size', size, 'created_at', created_at) order by created_at)
    from public.provider_documents where provider_id = v_uid), '[]'::jsonb);
end $$;

-- Depois de aprovado, os documentos passam a ser registro do credenciamento.
create function public.delete_document(p_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('provider');
begin
  if (select status from public.providers where id = v_uid) not in ('draft', 'pending', 'rejected') then
    perform app.fail('documents_locked', 'Documentos de um credenciamento ativo não podem ser removidos.');
  end if;
  delete from public.provider_documents where id = p_id and provider_id = v_uid;
  if not found then perform app.deny(); end if;
end $$;

-- Conteúdo do arquivo: só o próprio prestador e a HUB.
create function public.get_document(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid uuid := app.uid();
  d public.provider_documents;
begin
  select * into d from public.provider_documents where id = p_id;
  if d.id is null or not (d.provider_id = v_uid
      or exists (select 1 from public.profiles where id = v_uid and role = 'hub_admin')) then
    perform app.deny();
  end if;
  return jsonb_build_object('file_name', d.file_name, 'mime', d.mime, 'content_base64', encode(d.content, 'base64'));
end $$;

-- -----------------------------------------------------------------------------
-- Avisos: gerados por gatilhos, a partir do que já acontece no banco
-- -----------------------------------------------------------------------------
create function app.notify(p_user uuid, p_title text, p_body text, p_url text) returns void
language sql security definer set search_path = ''
as $$
  insert into public.notifications (user_id, title, body, url) values (p_user, p_title, p_body, p_url)
$$;

create function app.notify_admins(p_title text, p_body text, p_url text) returns void
language sql security definer set search_path = ''
as $$
  insert into public.notifications (user_id, title, body, url)
  select id, p_title, p_body, p_url from public.profiles where role = 'hub_admin'
$$;

create function app.on_request_event() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  r public.requests;
  v_service text;
  v_provider text;
  v_customer_url text;
  v_provider_url text;
  p record;
begin
  select * into r from public.requests where id = new.request_id;
  select name into v_service from public.services where id = r.service_id;
  select full_name into v_provider from public.profiles where id = r.provider_id;
  v_customer_url := '/cliente/pedidos/' || r.id;
  v_provider_url := '/prestador/pedidos/' || r.id;

  if new.kind = 'withdrawn' then
    perform app.notify(r.customer_id, 'Buscando outro prestador', 'O prestador não poderá atender seu pedido de ' || v_service || '. Já estamos procurando outro.', v_customer_url);
  end if;
  if new.kind in ('created', 'withdrawn') then
    -- Oferta aos prestadores disponíveis e habilitados na região.
    for p in select pr.id from public.providers pr where pr.online and app.can_take(pr.id, r.id) loop
      perform app.notify(p.id, 'Novo pedido: ' || v_service, 'Você recebe ' || app.brl(r.provider_net) || ' · ' || r.address, v_provider_url);
    end loop;
  elsif new.kind = 'accepted' then
    perform app.notify(r.customer_id, 'Prestador confirmado', v_provider || ' aceitou seu pedido de ' || v_service || '.', v_customer_url);
  elsif new.kind = 'en_route' then
    perform app.notify(r.customer_id, 'Prestador a caminho', v_provider || ' está indo até o seu carro.', v_customer_url);
  elsif new.kind = 'in_progress' then
    perform app.notify(r.customer_id, 'Serviço iniciado', v_provider || ' começou o serviço de ' || v_service || '.', v_customer_url);
  elsif new.kind = 'extra_proposed' then
    perform app.notify(r.customer_id, 'Orçamento adicional', 'O prestador enviou um orçamento: ' || coalesce(new.note, '') || '. Aprove ou recuse no aplicativo.', v_customer_url);
  elsif new.kind = 'completed' then
    perform app.notify(r.customer_id, 'Serviço concluído', 'Confira o resumo e pague ' || app.brl(r.total) || '.', v_customer_url);
  elsif new.kind in ('extra_approved', 'extra_rejected') and r.provider_id is not null then
    perform app.notify(r.provider_id, case when new.kind = 'extra_approved' then 'Adicional aprovado' else 'Adicional recusado' end,
      'O cliente respondeu ao seu orçamento do pedido nº ' || r.number || '.', v_provider_url);
  elsif new.kind = 'cancelled' and r.provider_id is not null then
    perform app.notify(r.provider_id, 'Pedido cancelado', 'O cliente cancelou o pedido nº ' || r.number || ' (' || v_service || ').', v_provider_url);
  elsif new.kind = 'payment_claimed' then
    perform app.notify_admins('Pagamento a confirmar', 'O cliente informou o Pix de ' || app.brl(r.total) || ' do pedido nº ' || r.number || '.', '/hub/pedidos');
  elsif new.kind = 'paid' then
    perform app.notify(r.provider_id, 'Pagamento confirmado', 'Repasse de ' || app.brl(r.provider_net) || ' previsto até ' || to_char(r.payout_due, 'DD/MM') || '.', v_provider_url);
    if new.actor = 'hub_admin' then
      perform app.notify(r.customer_id, 'Pagamento confirmado', 'Recebemos o pagamento do pedido nº ' || r.number || '. Avalie o atendimento.', v_customer_url);
    end if;
  elsif new.kind = 'payout' then
    perform app.notify(r.provider_id, 'Repasse realizado', 'A HUB registrou o repasse de ' || app.brl(r.provider_net) || ' do pedido nº ' || r.number || '.', v_provider_url);
  end if;
  return new;
end $$;
create trigger request_events_notify after insert on public.request_events
  for each row execute function app.on_request_event();

create function app.on_provider_status() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status = old.status then return new; end if;
  if new.status = 'pending' then
    perform app.notify_admins('Credenciamento para analisar', coalesce(new.legal_name, 'Novo prestador') || ' enviou o credenciamento.', '/hub/prestadores/' || new.id);
  elsif new.status = 'approved' and old.status = 'pending' then
    perform app.notify(new.id, 'Credenciamento aprovado', 'Você já pode ficar disponível para receber pedidos.', '/prestador');
  elsif new.status = 'rejected' then
    perform app.notify(new.id, 'Credenciamento não aprovado', 'Veja o motivo informado pela HUB e reenvie quando quiser.', '/prestador');
  elsif new.status = 'suspended' then
    perform app.notify(new.id, 'Credenciamento suspenso', 'Veja o motivo e conteste pelo aplicativo.', '/prestador');
  end if;
  return new;
end $$;
create trigger providers_status_notify after update of status on public.providers
  for each row execute function app.on_provider_status();

create function app.on_suspension_update() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.contested_at is not null and old.contested_at is null then
    perform app.notify_admins('Suspensão contestada', 'Um prestador contestou a suspensão. Reveja a medida.', '/hub/prestadores/' || new.provider_id);
  end if;
  if new.resolved_at is not null and old.resolved_at is null then
    perform app.notify(new.provider_id, case when new.resolution = 'lifted' then 'Suspensão encerrada' else 'Suspensão mantida' end,
      'A HUB registrou a revisão: ' || coalesce(new.resolution_note, ''), '/prestador');
  end if;
  return new;
end $$;
create trigger suspensions_notify after update on public.suspensions
  for each row execute function app.on_suspension_update();

-- Lista os avisos e marca todos como lidos.
create function public.my_notifications() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.uid();
  v_result jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'title', n.title, 'body', n.body, 'url', n.url,
      'created_at', n.created_at, 'unread', n.read_at is null) order by n.id desc), '[]'::jsonb) into v_result
  from (select * from public.notifications where user_id = v_uid order by id desc limit 40) n;
  update public.notifications set read_at = now() where user_id = v_uid and read_at is null;
  return v_result;
end $$;

create function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.uid();
begin
  if not exists (select 1 from public.profiles where id = v_uid) then perform app.deny(); end if;
  if coalesce(p_endpoint, '') !~ '^https://' or length(p_endpoint) > 1000 or length(coalesce(p_p256dh, '')) not between 20 and 200
     or length(coalesce(p_auth, '')) not between 10 and 100 then
    perform app.fail('invalid_subscription', 'Não foi possível ativar os avisos neste aparelho.');
  end if;
  insert into public.push_subscriptions (endpoint, user_id, p256dh, auth) values (p_endpoint, v_uid, p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

create function public.delete_push_subscription(p_endpoint text) returns void
language sql security definer set search_path = ''
as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid()
$$;

-- Fila de push (só o servidor do aplicativo): entrega cada aviso uma única vez.
create function public.push_take() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_result jsonb;
begin
  if coalesce(auth.role(), '') <> 'service_role' then perform app.deny(); end if;
  with picked as (
    select id from public.notifications where push_sent_at is null order by id limit 200 for update skip locked
  ), sent as (
    update public.notifications n set push_sent_at = now() from picked where n.id = picked.id returning n.*
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'body', s.body, 'url', s.url,
      'subscriptions', (select jsonb_agg(jsonb_build_object('endpoint', ps.endpoint, 'p256dh', ps.p256dh, 'auth', ps.auth))
        from public.push_subscriptions ps where ps.user_id = s.user_id))), '[]'::jsonb) into v_result
  from sent s
  where s.created_at > now() - interval '12 hours'
    and exists (select 1 from public.push_subscriptions ps where ps.user_id = s.user_id);
  return v_result;
end $$;

create function public.push_gone(p_endpoint text) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then perform app.deny(); end if;
  delete from public.push_subscriptions where endpoint = p_endpoint;
end $$;

-- =============================================================================
-- Privilégios: revoga tudo e libera somente a execução das funções da API.
-- =============================================================================
revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
revoke all on all routines in schema public from public, anon, authenticated, service_role;
revoke all on all routines in schema app from public, anon, authenticated, service_role;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' loop
    if f.proname in ('promote_hub_admin', 'push_take', 'push_gone', 'check_rate_limit', 'clear_rate_limit') then
      execute format('grant execute on function %s to service_role', f.sig);
    else
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;

-- >>> 20261116000400_initial_data.sql
-- =============================================================================
-- Zé do Carro — 04 Dados iniciais
-- Regras da plataforma, catálogo de serviços (cláusula 1.2 do contrato) e a
-- versão 1.0 do contrato de credenciamento.
--
-- ATENÇÃO: preços, comissão e prazo de repasse abaixo são VALORES DE PARTIDA
-- para o piloto, ajustáveis no painel da HUB. O contrato é a minuta 1.0, ainda
-- com campos a preencher ([CNPJ], [PERCENTUAL], [PRAZO]) e pendente de revisão
-- jurídica. O texto abaixo é gerado de supabase/contracts/credenciamento-v1.0.txt.
-- =============================================================================

insert into public.settings (id) values (true);

insert into public.services (code, name, description, base_price, est_minutes, sort) values
  ('troca_pneu', 'Troca de pneu', 'Troca do pneu furado pelo estepe ou por pneu novo fornecido pelo cliente.', 80.00, 30, 10),
  ('troca_oleo', 'Troca de óleo', 'Mão de obra da troca de óleo e filtro, com descarte correto do óleo usado. Óleo e filtro à parte.', 120.00, 40, 20),
  ('balanceamento', 'Balanceamento', 'Balanceamento das quatro rodas com equipamento móvel.', 100.00, 50, 30),
  ('alinhamento', 'Alinhamento', 'Alinhamento da direção com equipamento móvel.', 140.00, 60, 40),
  ('higienizacao_basica', 'Higienização básica', 'Limpeza e higienização interna básica do veículo.', 150.00, 90, 50);

insert into public.contract_versions (version, title, body, body_sha256, is_current)
select '1.0', 'Contrato de Credenciamento e Intermediação de Serviços Automotivos', c.body,
       encode(extensions.digest(c.body, 'sha256'), 'hex'), true
from (select $contrato$CONTRATO DE CREDENCIAMENTO E INTERMEDIAÇÃO DE SERVIÇOS AUTOMOTIVOS

HUB Tecnologia e Serviços Automotivos Ltda.

CONTRATANTE/PLATAFORMA: HUB Tecnologia e Serviços Automotivos Ltda., pessoa jurídica de direito privado, inscrita no CNPJ sob nº [CNPJ], com sede em [endereço].

PRESTADOR CREDENCIADO: [Nome ou razão social], inscrito no CPF/CNPJ sob nº [número], com endereço em [endereço].

As partes celebram o presente instrumento de credenciamento e intermediação tecnológica, nos termos das cláusulas seguintes.

CLÁUSULA 1 — DO OBJETO

1.1. O presente contrato estabelece as condições para o credenciamento do PRESTADOR em plataforma digital destinada à intermediação de serviços automotivos móveis.

1.2. Os serviços poderão compreender troca de pneus, alinhamento, balanceamento, troca de óleo, higienização automotiva básica e outros procedimentos tecnicamente habilitados e legalmente permitidos.

1.3. A inclusão de novos serviços dependerá da verificação dos requisitos técnicos, ambientais e regulatórios aplicáveis.

CLÁUSULA 2 — DA NATUREZA DA RELAÇÃO

2.1. O PRESTADOR atuará como profissional autônomo ou empresa independente, sem exclusividade, subordinação jurídica ou obrigação de disponibilidade permanente perante a HUB.

2.2. O presente instrumento possui natureza civil e comercial, não constituindo, por si só, relação de emprego, sociedade, representação comercial ou mandato geral entre as partes.

2.3. As disposições deste contrato deverão corresponder à efetiva autonomia profissional exercida na prática, observada a legislação aplicável.

CLÁUSULA 3 — DA AUTONOMIA PROFISSIONAL

3.1. O PRESTADOR terá plena liberdade para estabelecer os dias, horários e regiões em que deseja disponibilizar seus serviços.

3.2. A conexão à plataforma ocorrerá por iniciativa do PRESTADOR, sem obrigação de jornada mínima, escala, plantão ou quantidade mínima de atendimentos.

3.3. O PRESTADOR poderá aceitar ou recusar solicitações, sem penalidades ou redução de classificação decorrentes exclusivamente da recusa.

3.4. Será permitida a prestação de serviços para empresas concorrentes, oficinas, clientes particulares e outras plataformas.

3.5. O PRESTADOR poderá interromper sua disponibilidade a qualquer momento, respeitadas as obrigações assumidas nos atendimentos previamente aceitos.

CLÁUSULA 4 — DO CREDENCIAMENTO E DA QUALIFICAÇÃO

4.1. O acesso às solicitações dependerá de aprovação em procedimento de credenciamento técnico e documental.

4.2. A HUB poderá aplicar provas de conhecimentos, avaliações práticas e verificações de certificações relativas aos serviços pretendidos.

4.3. A aprovação atestará o cumprimento dos requisitos mínimos de credenciamento e não constituirá promessa de contratação, remuneração ou quantidade de serviços.

4.4. A reavaliação técnica poderá ocorrer mediante critérios objetivos e previamente informados, especialmente em caso de atualização tecnológica ou ocorrência relacionada à segurança.

CLÁUSULA 5 — DOS EQUIPAMENTOS E PRODUTOS

5.1. O PRESTADOR utilizará ferramentas, equipamentos e produtos compatíveis com as especificações técnicas e de segurança divulgadas pela HUB.

5.2. Os equipamentos e produtos poderão ser adquiridos de fornecedores livremente escolhidos pelo PRESTADOR, desde que atendam aos requisitos objetivos de compatibilidade e qualidade.

5.3. A HUB poderá oferecer kits padronizados para aquisição facultativa, sem exigir compra exclusiva de sua própria rede comercial.

5.4. A manutenção, conservação e regularidade dos equipamentos próprios serão de responsabilidade do PRESTADOR, observadas as regras legais aplicáveis.

CLÁUSULA 6 — DO ACEITE E DA EXECUÇÃO DOS SERVIÇOS

6.1. As solicitações serão apresentadas no aplicativo, contendo, quando disponível, localização, natureza do atendimento, estimativa de preço, remuneração líquida e condições relevantes.

6.2. O PRESTADOR decidirá livremente sobre o aceite.

6.3. Após o aceite, comprometer-se-á a executar o serviço contratado com diligência técnica, segurança e observância das condições informadas ao cliente.

6.4. O PRESTADOR manterá autonomia sobre os procedimentos técnicos adequados, respeitadas as normas legais, as instruções dos fabricantes e as especificações de segurança.

6.5. Serviços adicionais dependerão de orçamento e autorização do cliente, registrados na plataforma.

6.6. A eventual substituição do profissional executor somente poderá ocorrer por outro profissional devidamente credenciado e habilitado, mediante comunicação e concordância do cliente quando necessária.

CLÁUSULA 7 — DA REMUNERAÇÃO E DAS COMISSÕES

7.1. A remuneração decorrerá dos serviços efetivamente contratados e executados, não havendo salário fixo ou garantia de faturamento mínimo.

7.2. A HUB receberá uma comissão de [PERCENTUAL]% sobre a base de cálculo definida no Anexo Financeiro.

7.3. Antes de aceitar cada solicitação, o PRESTADOR terá acesso à estimativa de sua remuneração líquida e aos descontos aplicáveis.

7.4. Os pagamentos serão processados por instituição ou prestador de serviços de pagamento integrado à plataforma, observadas as regras financeiras e regulatórias aplicáveis.

7.5. Os repasses ocorrerão em até [PRAZO] após a confirmação das condições para liberação do pagamento, ressalvadas contestações, estornos e retenções justificadas e legalmente admitidas.

7.6. Tributos e obrigações fiscais serão tratados conforme a natureza jurídica da operação e a condição tributária de cada parte.

CLÁUSULA 8 — DAS RESPONSABILIDADES DA HUB

Compete à HUB:

a) Disponibilizar e administrar a plataforma tecnológica.

b) Realizar o credenciamento e a verificação documental dos profissionais.

c) Estabelecer requisitos objetivos de qualidade e segurança.

d) Intermediar solicitações, pagamentos e canais de atendimento.

e) Oferecer mecanismos de reclamação, avaliação e solução de conflitos.

f) Cumprir as obrigações legais que lhe sejam atribuídas, inclusive perante consumidores e titulares de dados.

CLÁUSULA 9 — DAS RESPONSABILIDADES DO PRESTADOR

Compete ao PRESTADOR:

a) Manter válidas as habilitações e autorizações exigíveis.

b) Utilizar produtos e equipamentos adequados.

c) Cumprir os serviços que livremente aceitar, ressalvadas situações justificadas.

d) Observar exigências de segurança, proteção ambiental e destinação de resíduos.

e) Registrar corretamente a realização do atendimento.

f) Preservar os bens e a privacidade dos clientes.

g) Responder por sua conduta e pelas falhas que lhe sejam legalmente imputáveis, sem prejuízo da responsabilidade de outros integrantes da cadeia de fornecimento.

CLÁUSULA 10 — DO CONTROLE DE QUALIDADE

10.1. A HUB poderá verificar a conformidade dos serviços prestados mediante avaliações dos clientes, documentos, registros técnicos e auditorias proporcionais.

10.2. O controle de qualidade terá por finalidade a segurança, a regularidade dos serviços e a proteção dos consumidores, não constituindo autorização para impor jornadas ou exercer direção cotidiana sobre a atividade do PRESTADOR.

10.3. A recusa de chamados ou a ausência de conexão à plataforma não será utilizada, isoladamente, como fundamento de punição.

CLÁUSULA 11 — DA SUSPENSÃO DO CREDENCIAMENTO

11.1. O credenciamento poderá ser suspenso por motivos objetivos, como fraude comprovada, perda de habilitação, utilização de equipamentos inseguros ou descumprimento grave das obrigações contratuais.

11.2. A HUB comunicará os motivos da medida e oferecerá mecanismo de contestação e revisão, ressalvadas medidas cautelares urgentes para prevenção de danos.

11.3. Eventuais prejuízos e ressarcimentos serão apurados segundo a responsabilidade efetiva das partes, vedados descontos arbitrários.

CLÁUSULA 12 — DA PROTEÇÃO DE DADOS

12.1. As partes observarão a Lei Geral de Proteção de Dados Pessoais — LGPD.

12.2. O PRESTADOR acessará apenas os dados necessários à realização dos serviços aceitos.

12.3. Ficam vedados o compartilhamento não autorizado, a comercialização de dados e o uso de informações dos clientes para finalidades incompatíveis com o atendimento.

12.4. O tratamento de dados de localização deverá ser limitado às finalidades legítimas de disponibilização, execução e segurança dos serviços, com transparência ao titular.

CLÁUSULA 13 — DA RESPONSABILIDADE PERANTE TERCEIROS

13.1. Cada parte responderá por seus atos e omissões na extensão de sua responsabilidade legal.

13.2. A distribuição contratual das responsabilidades não afastará direitos dos consumidores, garantias legais ou hipóteses de responsabilidade solidária previstas na legislação.

13.3. Os procedimentos de reclamação, reembolso, garantia e ressarcimento observarão a legislação aplicável e os termos apresentados ao consumidor.

CLÁUSULA 14 — DA VIGÊNCIA E DO ENCERRAMENTO

14.1. O presente contrato terá vigência por prazo indeterminado.

14.2. Qualquer parte poderá solicitar o encerramento do credenciamento, respeitados os atendimentos já assumidos, os valores pendentes e as obrigações legais sobreviventes.

14.3. A rescisão não prejudicará o pagamento de remunerações devidas por serviços efetivamente prestados.

CLÁUSULA 15 — DAS DISPOSIÇÕES FINAIS

15.1. O contrato poderá ser formalizado eletronicamente, mediante mecanismo que assegure a identificação do signatário, a integridade do documento e o registro do aceite.

15.2. Alterações relevantes serão comunicadas previamente, sendo apresentado novo termo para aceitação quando necessário.

15.3. Os litígios serão submetidos ao juízo legalmente competente, respeitadas as regras de competência obrigatória.

15.4. Integram este instrumento os anexos referentes aos serviços autorizados, requisitos dos equipamentos, política de remuneração e procedimentos de segurança.

Local e data: São Luís/MA, [DATA].

Versão do contrato: 1.0 — minuta para revisão jurídica.$contrato$::text as body) c;
