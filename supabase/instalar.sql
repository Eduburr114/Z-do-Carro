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

commit;

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

commit;

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

commit;

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

commit;

-- >>> 20261117000100_finance_types.sql
-- =============================================================================
-- Zé do Carro — 05 Financeiro: novos valores de tipos
-- Fica sozinha porque o PostgreSQL só deixa usar um valor novo de enum depois
-- que a transação que o criou termina. A CLI do Supabase aplica cada migração
-- em uma transação própria; o instalar.sql faz COMMIT entre os arquivos.
-- =============================================================================

-- Pedido criado e ainda sem pagamento confirmado pelo provedor: não é oferecido
-- a nenhum prestador.
alter type public.request_status add value if not exists 'awaiting_payment' before 'searching';

-- Adicional aprovado que deixou de ser feito (por exemplo, o cliente não pagou).
alter type public.extra_status add value if not exists 'cancelled';

commit;

-- >>> 20261117000200_finance_schema.sql
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

commit;

-- >>> 20261117000300_finance_core.sql
-- =============================================================================
-- Zé do Carro — 07 Financeiro: regras internas (schema app, fora da API)
-- Máquina de estados financeira, razão contábil, preço, comissão, auditoria e
-- fila de e-mails. As funções públicas (RPC) ficam no arquivo seguinte.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Equipe e papéis
-- -----------------------------------------------------------------------------
create function app.is_staff(p_uid uuid, p_role text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.profiles p join public.staff_roles s on s.user_id = p.id
    where p.id = p_uid and p.role = 'hub_admin' and s.role = p_role)
$$;

create function app.require_staff(p_role text) returns uuid
language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := app.uid();
begin
  if not app.is_staff(v_uid, p_role) then perform app.deny(); end if;
  return v_uid;
end $$;

-- Qualquer pessoa da equipe (admin ou financeiro).
create function app.require_any_staff() returns uuid
language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := app.uid();
begin
  if not (app.is_staff(v_uid, 'admin') or app.is_staff(v_uid, 'finance')) then perform app.deny(); end if;
  return v_uid;
end $$;

-- A administração operacional (credenciamento, catálogo, comissões) passa a
-- exigir o papel interno 'admin'; o gestor financeiro sozinho não a acessa.
create or replace function app.require_role(p_role public.user_role) returns uuid
language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := app.uid();
begin
  if not exists (select 1 from public.profiles where id = v_uid and role = p_role) then
    perform app.deny();
  end if;
  if p_role = 'hub_admin' and not app.is_staff(v_uid, 'admin') then perform app.deny(); end if;
  return v_uid;
end $$;

-- -----------------------------------------------------------------------------
-- Utilidades
-- -----------------------------------------------------------------------------
create function app.cents(p numeric) returns bigint
language sql immutable set search_path = ''
as $$ select (round(p * 100))::bigint $$;

create function app.brl_cents(p bigint) returns text
language sql immutable set search_path = ''
as $$ select app.brl(p / 100.0) $$;

create function app.valid_cpf(p text) returns boolean
language plpgsql immutable set search_path = ''
as $$
declare d int[]; s int; r int; i int;
begin
  if p !~ '^[0-9]{11}$' or p ~ '^(.)\1{10}$' then return false; end if;
  d := array(select substr(p, g, 1)::int from generate_series(1, 11) g);
  s := 0; for i in 1..9 loop s := s + d[i] * (11 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  if r <> d[10] then return false; end if;
  s := 0; for i in 1..10 loop s := s + d[i] * (12 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  return r = d[11];
end $$;

create function app.valid_cnpj(p text) returns boolean
language plpgsql immutable set search_path = ''
as $$
declare d int[]; w1 int[] := array[5,4,3,2,9,8,7,6,5,4,3,2]; w2 int[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2]; s int; r int; i int;
begin
  if p !~ '^[0-9]{14}$' or p ~ '^(.)\1{13}$' then return false; end if;
  d := array(select substr(p, g, 1)::int from generate_series(1, 14) g);
  s := 0; for i in 1..12 loop s := s + d[i] * w1[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  if r <> d[13] then return false; end if;
  s := 0; for i in 1..13 loop s := s + d[i] * w2[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  return r = d[14];
end $$;

-- Limite de tentativas dentro do banco (por usuário e operação).
create function app.hit(p_key text, p_max integer, p_window_seconds integer) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_count integer;
begin
  delete from public.rate_limits where key = p_key and window_start < now() - make_interval(secs => p_window_seconds);
  insert into public.rate_limits (key, count) values (p_key, 1)
  on conflict (key) do update set count = public.rate_limits.count + 1
  returning count into v_count;
  if v_count > p_max then
    perform app.fail('rate_limited', 'Muitas tentativas em pouco tempo. Aguarde alguns minutos e tente de novo.');
  end if;
end $$;

create function app.require_service_role() returns void
language plpgsql stable set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then perform app.deny(); end if;
end $$;

-- -----------------------------------------------------------------------------
-- Auditoria e registros somente de inclusão
-- -----------------------------------------------------------------------------
create function app.append_only() returns trigger
language plpgsql set search_path = ''
as $$
begin
  raise exception using errcode = 'P0001', message = 'immutable_record',
    detail = 'Registros financeiros e de auditoria não podem ser alterados nem apagados.';
end $$;

create function app.audit_row() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) - 'setup_code_hash' - 'pix_qr_image' end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) - 'setup_code_hash' - 'pix_qr_image' end;
  v_row jsonb;
  v_key text;
begin
  if tg_op = 'UPDATE' and v_old = v_new then return new; end if;
  v_row := coalesce(v_new, v_old);
  v_key := v_row ->> coalesce(tg_argv[0], 'id');
  if tg_nargs > 1 then v_key := v_key || '/' || coalesce(v_row ->> tg_argv[1], ''); end if;
  insert into public.audit_logs (actor_id, actor_role, action, entity, entity_id, before, after, note)
  values (auth.uid(), coalesce(auth.role(), current_user), lower(tg_op), tg_table_name, v_key, v_old, v_new,
    nullif(current_setting('app.audit_note', true), ''));
  return coalesce(new, old);
end $$;

create function app.audit(p_action text, p_entity text, p_entity_id text, p_after jsonb default null, p_note text default null) returns void
language sql security definer set search_path = ''
as $$
  insert into public.audit_logs (actor_id, actor_role, action, entity, entity_id, after, note)
  values (auth.uid(), coalesce(auth.role(), current_user), p_action, p_entity, p_entity_id, p_after, p_note)
$$;

create trigger audit_logs_append_only before update or delete on public.audit_logs for each row execute function app.append_only();
create trigger financial_ledger_append_only before update or delete on public.financial_ledger for each row execute function app.append_only();
create trigger financial_events_append_only before update or delete on public.financial_events for each row execute function app.append_only();
create trigger audit_logs_no_truncate before truncate on public.audit_logs for each statement execute function app.append_only();
create trigger financial_ledger_no_truncate before truncate on public.financial_ledger for each statement execute function app.append_only();
create trigger financial_events_no_truncate before truncate on public.financial_events for each statement execute function app.append_only();

create trigger settings_audit after update on public.settings for each row execute function app.audit_row('id');
create trigger services_audit after insert or update on public.services for each row execute function app.audit_row();
create trigger service_prices_audit after insert or update or delete on public.service_prices for each row execute function app.audit_row('service_id', 'region_id');
create trigger service_categories_audit after insert or update on public.service_categories for each row execute function app.audit_row('code');
create trigger regions_audit after insert or update on public.regions for each row execute function app.audit_row();
create trigger promotions_audit after insert or update on public.promotions for each row execute function app.audit_row();
create trigger commission_rules_audit after insert or update on public.commission_rules for each row execute function app.audit_row();
create trigger staff_roles_audit after insert or delete on public.staff_roles for each row execute function app.audit_row('user_id', 'role');
create trigger provider_accounts_audit after insert or update on public.provider_payment_accounts for each row execute function app.audit_row();
create trigger payouts_audit after insert or update on public.payouts for each row execute function app.audit_row();
create trigger refunds_audit after insert or update on public.refunds for each row execute function app.audit_row();
create trigger withdrawal_auth_audit after insert or update on public.withdrawal_authorizations for each row execute function app.audit_row();

-- Regra de comissão é imutável: só se encerra (active = false ou ends_at).
create function app.guard_commission_rule() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.percent <> old.percent or new.scope <> old.scope or new.category_code is distinct from old.category_code
     or new.provider_id is distinct from old.provider_id or new.starts_at is distinct from old.starts_at
     or (old.ends_at is not null and new.ends_at is distinct from old.ends_at and new.ends_at > old.ends_at)
     or (new.active and not old.active) then
    raise exception using errcode = 'P0001', message = 'immutable_record',
      detail = 'Uma regra de comissão não pode ser alterada. Encerre esta e crie outra.';
  end if;
  return new;
end $$;
create trigger commission_rules_guard before update on public.commission_rules for each row execute function app.guard_commission_rule();

-- -----------------------------------------------------------------------------
-- Razão contábil em partidas dobradas
-- -----------------------------------------------------------------------------
create function app.ledger_balanced() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_diff bigint;
begin
  select coalesce(sum(case when direction = 'D' then amount_cents else -amount_cents end), 0) into v_diff
  from public.financial_ledger where journal_id = new.journal_id;
  if v_diff <> 0 then
    raise exception using errcode = 'P0001', message = 'ledger_unbalanced', detail = 'Lançamento contábil desbalanceado.';
  end if;
  return null;
end $$;
create constraint trigger financial_ledger_balanced after insert on public.financial_ledger
  deferrable initially deferred for each row execute function app.ledger_balanced();

-- Lança um jornal. p_lines: [{"a": conta, "d": "D"|"C", "c": centavos}]; linhas
-- com zero são ignoradas.
create function app.journal(p_memo text, p_lines jsonb, p_request uuid default null, p_payment uuid default null,
  p_payout uuid default null, p_refund uuid default null) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_journal uuid := gen_random_uuid();
  v_provider uuid;
  v_sum bigint := 0;
  v_lines integer := 0;
  l jsonb;
  v_amount bigint;
begin
  if p_request is not null then select provider_id into v_provider from public.requests where id = p_request; end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    v_amount := (l ->> 'c')::bigint;
    if v_amount < 0 then perform app.fail('ledger_negative', 'Valor negativo em lançamento contábil.'); end if;
    continue when v_amount = 0;
    insert into public.financial_ledger (journal_id, account, direction, amount_cents, request_id, payment_id, payout_id, refund_id, provider_id, memo)
    values (v_journal, l ->> 'a', l ->> 'd', v_amount, p_request, p_payment, p_payout, p_refund, v_provider, p_memo);
    v_sum := v_sum + case when l ->> 'd' = 'D' then v_amount else -v_amount end;
    v_lines := v_lines + 1;
  end loop;
  if v_sum <> 0 then perform app.fail('ledger_unbalanced', 'Lançamento contábil desbalanceado.'); end if;
  return case when v_lines = 0 then null else v_journal end;
end $$;

create function app.line(p_account text, p_direction text, p_cents bigint) returns jsonb
language sql immutable set search_path = ''
as $$ select jsonb_build_object('a', p_account, 'd', p_direction, 'c', p_cents) $$;

-- -----------------------------------------------------------------------------
-- Máquina de estados financeira do pedido
-- -----------------------------------------------------------------------------
create function app.fin_allowed(p_from text, p_to text) returns boolean
language sql immutable set search_path = ''
as $$
  select case p_from
    when 'pending_payment' then p_to in ('payment_confirmed', 'cancelled')
    when 'payment_confirmed' then p_to in ('service_in_progress', 'refund_pending')
    when 'service_in_progress' then p_to in ('service_completed', 'refund_pending')
    when 'service_completed' then p_to in ('payout_scheduled', 'refund_pending', 'disputed')
    when 'payout_scheduled' then p_to in ('payout_processing', 'refund_pending', 'disputed')
    when 'payout_processing' then p_to in ('payout_completed', 'payout_failed')
    when 'payout_failed' then p_to in ('payout_scheduled', 'payout_processing', 'refund_pending', 'disputed')
    when 'payout_completed' then p_to in ('refund_pending')
    when 'disputed' then p_to in ('payout_scheduled', 'refund_pending')
    when 'refund_pending' then p_to in ('refunded')
    else false end
$$;

-- Toda mudança de estado financeiro, venha de onde vier, passa por aqui: valida
-- a transição, mantém as colunas antigas coerentes e registra o evento.
create function app.guard_request() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.price is distinct from old.price or new.discount_amount is distinct from old.discount_amount
     or new.fee_amount is distinct from old.fee_amount or new.promotion_id is distinct from old.promotion_id
     or new.region_id is distinct from old.region_id or new.pricing_snapshot is distinct from old.pricing_snapshot
     or new.base_commission_percent is distinct from old.base_commission_percent
     or new.customer_id is distinct from old.customer_id or new.service_id is distinct from old.service_id then
    raise exception using errcode = 'P0001', message = 'immutable_record',
      detail = 'O preço aceito na contratação não pode ser alterado.';
  end if;
  if (new.commission_percent is distinct from old.commission_percent or new.commission_rule_id is distinct from old.commission_rule_id
      or new.payout_days_snapshot is distinct from old.payout_days_snapshot)
     and not (new.provider_id is distinct from old.provider_id and old.status in ('searching', 'accepted', 'en_route')) then
    raise exception using errcode = 'P0001', message = 'immutable_record',
      detail = 'A comissão fica registrada no aceite e não muda depois.';
  end if;
  if old.recognized_journal is not null and (new.total <> old.total or new.provider_net <> old.provider_net) then
    raise exception using errcode = 'P0001', message = 'immutable_record', detail = 'Valores de um pedido já reconhecido não mudam.';
  end if;
  if new.financial_status is distinct from old.financial_status then
    if not app.fin_allowed(old.financial_status, new.financial_status) then
      raise exception using errcode = 'P0001', message = 'invalid_financial_transition',
        detail = format('Transição financeira não permitida: %s → %s.', old.financial_status, new.financial_status);
    end if;
    new.payment_status := case
      when new.financial_status = 'refunded' then 'refunded'
      when new.financial_status in ('pending_payment', 'cancelled') then 'pending'
      else 'paid' end::public.payment_status;
    new.payout_status := case
      when new.financial_status = 'payout_completed' then 'paid'
      when new.financial_status in ('payout_scheduled', 'payout_processing', 'payout_failed') then 'pending'
      else 'none' end::public.payout_status;
    insert into public.financial_events (request_id, from_status, to_status, actor_id, note)
    values (new.id, old.financial_status, new.financial_status, auth.uid(), nullif(current_setting('app.fin_note', true), ''));
  end if;
  return new;
end $$;
create trigger requests_guard before update on public.requests for each row execute function app.guard_request();

create function app.fin_set(p_request uuid, p_to text, p_note text default null) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform set_config('app.fin_note', coalesce(p_note, ''), true);
  update public.requests set financial_status = p_to where id = p_request and financial_status <> p_to;
  perform set_config('app.fin_note', '', true);
end $$;

-- -----------------------------------------------------------------------------
-- Preço e comissão
-- -----------------------------------------------------------------------------
create function app.region_for(p_lat double precision, p_lng double precision) returns uuid
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select r.id from public.regions r
      where r.active and p_lat is not null and p_lng is not null and app.km(p_lat, p_lng, r.center_lat, r.center_lng) <= r.radius_km
      order by app.km(p_lat, p_lng, r.center_lat, r.center_lng) limit 1),
    (select r.id from public.regions r join public.settings s on s.default_region_id = r.id where r.active))
$$;

-- Comissão vigente em p_at. Prioridade: prestador > campanha > categoria > padrão.
create function app.commission_for(p_category text, p_provider uuid, p_at timestamptz) returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select jsonb_build_object('percent', r.percent, 'rule_id', r.id, 'source', r.scope, 'name', r.name)
      from public.commission_rules r
      where r.active and (r.starts_at is null or r.starts_at <= p_at) and (r.ends_at is null or r.ends_at > p_at)
        and ((r.scope = 'provider' and r.provider_id = p_provider and (r.category_code is null or r.category_code = p_category))
          or (r.scope = 'campaign' and (r.category_code is null or r.category_code = p_category))
          or (r.scope = 'category' and r.category_code = p_category))
      order by case r.scope when 'provider' then 3 when 'campaign' then 2 else 1 end desc, r.created_at desc
      limit 1),
    (select jsonb_build_object('percent', s.commission_percent, 'rule_id', null, 'source', 'default', 'name', 'Comissão padrão')
      from public.settings s))
$$;

-- Orçamento do serviço: preço da região (ou de tabela), melhor promoção vigente
-- e taxa da plataforma. É o que o cliente vê antes de confirmar.
create function app.quote(p_service uuid, p_lat double precision, p_lng double precision) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  s public.services;
  st public.settings;
  v_region public.regions;
  v_price numeric(12,2);
  v_promo public.promotions;
  v_discount numeric(12,2) := 0;
  v_total numeric(12,2);
begin
  select * into s from public.services where id = p_service and active;
  if s.id is null then return null; end if;
  select * into st from public.settings;
  select * into v_region from public.regions where id = app.region_for(p_lat, p_lng);
  select sp.price into v_price from public.service_prices sp where sp.service_id = s.id and sp.region_id = v_region.id and sp.active;
  v_price := coalesce(v_price, s.base_price);
  select p.* into v_promo from public.promotions p
  where p.active and p.starts_at <= now() and p.ends_at > now()
    and (p.max_redemptions is null or p.redemptions < p.max_redemptions)
    and (p.service_id is null or p.service_id = s.id)
    and (p.category_code is null or p.category_code = s.category_code)
    and (p.region_id is null or p.region_id = v_region.id)
  order by case when p.kind = 'percent' then round(v_price * p.value / 100, 2) else least(p.value, v_price) end desc, p.created_at
  limit 1;
  if v_promo.id is not null then
    v_discount := case when v_promo.kind = 'percent' then round(v_price * v_promo.value / 100, 2) else least(v_promo.value, v_price) end;
    -- O total nunca fica abaixo da cobrança mínima.
    v_discount := greatest(0, least(v_discount, v_price + st.platform_fee - st.min_charge_amount));
  end if;
  v_total := v_price - v_discount + st.platform_fee;
  return jsonb_build_object(
    'service_id', s.id, 'service_name', s.name, 'category_code', s.category_code,
    'region_id', v_region.id, 'region_name', v_region.name,
    'list_price', v_price, 'discount', v_discount,
    'promotion_id', case when v_discount > 0 then v_promo.id end,
    'promotion_name', case when v_discount > 0 then v_promo.name end,
    'fee', st.platform_fee, 'total', v_total, 'min_charge', st.min_charge_amount, 'quoted_at', now());
end $$;

-- Total, comissão e líquido a partir dos adicionais aprovados. O desconto é
-- custeado pela plataforma: o líquido do prestador usa o preço de tabela.
create or replace function app.recalc(p_request uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_extras numeric(12,2);
begin
  select coalesce(sum(price), 0) into v_extras
  from public.request_extras where request_id = p_request and status = 'approved';
  update public.requests r set
    extras_total = v_extras,
    total = r.price - r.discount_amount + r.fee_amount + v_extras,
    commission_amount = round((r.price + v_extras) * r.commission_percent / 100, 2),
    provider_net = (r.price + v_extras) - round((r.price + v_extras) * r.commission_percent / 100, 2)
  where r.id = p_request;
end $$;

-- Comissão de um pedido para um prestador: a registrada na criação do pedido,
-- salvo regra vigente específica do prestador (que só se conhece no aceite).
create function app.request_commission(p_request uuid, p_provider uuid) returns jsonb
language sql stable security definer set search_path = ''
as $$
  select case when c ->> 'source' = 'provider' then c else r.pricing_snapshot -> 'commission' end
  from public.requests r join public.services s on s.id = r.service_id
  cross join lateral (select app.commission_for(s.category_code, p_provider, now()) as c) x
  where r.id = p_request
$$;

-- Condições que um prestador específico teria ao aceitar o pedido agora.
create function app.offer_terms(p_request uuid, p_provider uuid) returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('commission_percent', c.pct,
    'commission_amount', round((r.price + r.extras_total) * c.pct / 100, 2),
    'provider_net', (r.price + r.extras_total) - round((r.price + r.extras_total) * c.pct / 100, 2))
  from public.requests r
  cross join lateral (select (app.request_commission(r.id, p_provider) ->> 'percent')::numeric as pct) c
  where r.id = p_request
$$;

-- -----------------------------------------------------------------------------
-- Avisos e e-mails
-- -----------------------------------------------------------------------------
create function app.notify_staff(p_role text, p_title text, p_body text, p_url text) returns void
language sql security definer set search_path = ''
as $$
  insert into public.notifications (user_id, title, body, url)
  select s.user_id, p_title, p_body, p_url from public.staff_roles s where s.role = p_role
$$;

-- Põe um e-mail na fila. A chave de idempotência impede envio em dobro.
create function app.email(p_user uuid, p_template text, p_data jsonb, p_key text) returns void
language sql security definer set search_path = ''
as $$
  insert into public.notification_logs (template, user_id, to_email, data, idempotency_key)
  select p_template, p_user, u.email, coalesce(p_data, '{}'::jsonb), p_key
  from auth.users u where u.id = p_user and u.email is not null
  on conflict (idempotency_key) do nothing
$$;

create function app.email_staff(p_role text, p_template text, p_data jsonb, p_key text) returns void
language sql security definer set search_path = ''
as $$
  select app.email(s.user_id, p_template, p_data, p_key || ':' || s.user_id) from public.staff_roles s where s.role = p_role
$$;

-- Alerta para a equipe financeira: aviso no aplicativo e e-mail.
create function app.finance_alert(p_title text, p_body text, p_url text, p_key text) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.notify_staff('finance', p_title, p_body, p_url);
  perform app.email_staff('finance', 'alerta_financeiro', jsonb_build_object('title', p_title, 'body', p_body, 'url', p_url), 'alert:' || p_key);
end $$;

-- -----------------------------------------------------------------------------
-- Pagamentos: confirmação, órfãos, estornos
-- -----------------------------------------------------------------------------
create function app.request_refund_payment(p_payment uuid, p_reason text, p_note text default null) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  p public.payments;
  v_id uuid;
begin
  select * into p from public.payments where id = p_payment for update;
  if p.status <> 'confirmed' then perform app.fail('not_refundable', 'Só um pagamento confirmado pode ser estornado.'); end if;
  insert into public.refunds (payment_id, amount_cents, reason, note, requested_by)
  values (p.id, p.amount_cents, p_reason, p_note, auth.uid()) returning id into v_id;
  update public.payments set status = 'refund_pending', updated_at = now() where id = p.id;
  return v_id;
end $$;

-- Dinheiro confirmado pelo provedor (ou pela equipe, no modo manual). Decide se
-- libera o pedido ou se o pagamento é órfão (atrasado/duplicado) e será estornado.
create function app.apply_confirmed(p_payment uuid, p_value_cents bigint, p_net_cents bigint) returns text
language plpgsql security definer set search_path = ''
as $$
declare
  p public.payments;
  r public.requests;
  v_extra public.request_extras;
  v_orphan text;
  v_fee bigint;
begin
  select * into p from public.payments where id = p_payment for update;
  select * into r from public.requests where id = p.request_id for update;
  if p.kind = 'extra' then select * into v_extra from public.request_extras where id = p.extra_id; end if;

  if exists (select 1 from public.payments o where o.id <> p.id and o.request_id = p.request_id
      and o.extra_id is not distinct from p.extra_id and o.orphan_reason is null
      and o.status in ('confirmed', 'refund_pending', 'refunded')) then
    v_orphan := 'duplicate';
  elsif p_value_cents <> p.amount_cents then
    v_orphan := 'amount_mismatch';
  elsif p.kind = 'service' and (r.status <> 'awaiting_payment' or r.financial_status <> 'pending_payment') then
    v_orphan := 'late_payment';
  elsif p.kind = 'extra' and (v_extra.status <> 'approved' or r.status not in ('in_progress')) then
    v_orphan := 'late_payment';
  end if;

  v_fee := greatest(p_value_cents - coalesce(p_net_cents, p_value_cents), 0);
  update public.payments set status = 'confirmed', orphan_reason = v_orphan, confirmed_at = now(),
    net_cents = coalesce(p_net_cents, p_value_cents), fee_cents = v_fee, updated_at = now(), remote_cancel_pending = false
  where id = p.id;

  -- O dinheiro entrou no provedor, seja qual for o destino.
  perform app.journal('Pagamento recebido', jsonb_build_array(
      app.line('cash_gateway', 'D', p_value_cents - v_fee),
      app.line('gateway_fees', 'D', v_fee),
      app.line('customer_funds_held', 'C', p_value_cents)),
    p.request_id, p.id);

  if v_orphan is not null then
    perform app.request_refund_payment(p.id, v_orphan,
      case v_orphan when 'duplicate' then 'Pagamento em duplicidade.' when 'late_payment' then 'Pagamento após o cancelamento ou o prazo.'
      else 'Valor recebido diferente do cobrado.' end);
    perform app.log(p.request_id, 'payment_orphan', null, v_orphan);
    return v_orphan;
  end if;

  if p.kind = 'service' then
    update public.requests set status = 'searching', paid_at = now() where id = r.id;
    perform app.fin_set(r.id, 'payment_confirmed', 'Pagamento confirmado pelo provedor');
    if r.promotion_id is not null then
      update public.promotions set redemptions = redemptions + 1 where id = r.promotion_id;
    end if;
    perform app.log(r.id, 'paid', null);
  else
    perform app.log(r.id, 'extra_paid', null, v_extra.description);
  end if;
  return 'applied';
end $$;

create function app.apply_refunded(p_payment uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  p public.payments;
  r public.requests;
  v_refund uuid;
begin
  select * into p from public.payments where id = p_payment for update;
  if p.status = 'refunded' then return; end if;
  if p.status not in ('confirmed', 'refund_pending') then return; end if;
  -- Estorno iniciado fora do aplicativo (pelo painel do provedor): registra.
  select id into v_refund from public.refunds where payment_id = p.id and status <> 'failed';
  if v_refund is null then
    insert into public.refunds (payment_id, amount_cents, reason, note, status)
    values (p.id, p.amount_cents, 'finance', 'Estorno feito diretamente no provedor', 'processing') returning id into v_refund;
    if p.orphan_reason is null then
      perform app.finance_alert('Estorno feito fora do aplicativo',
        'Um pagamento foi estornado diretamente no provedor. Confira o pedido e o repasse.', '/hub/financeiro', 'ext-refund:' || p.id);
    end if;
  end if;
  update public.refunds set status = 'done', done_at = now() where id = v_refund;
  update public.payments set status = 'refunded', refunded_at = now(), updated_at = now() where id = p.id;
  perform app.journal('Estorno ao cliente', jsonb_build_array(
      app.line('customer_funds_held', 'D', p.amount_cents),
      app.line('cash_gateway', 'C', p.amount_cents)),
    p.request_id, p.id, null, v_refund);

  if p.orphan_reason is not null then return; end if;
  select * into r from public.requests where id = p.request_id for update;
  if r.financial_status not in ('refund_pending', 'refunded') then
    -- Estorno externo de um pagamento válido: reverte o pedido e trava o repasse.
    perform app.reverse_and_refund(r.id, 'Estorno feito diretamente no provedor', true);
  end if;
  if not exists (select 1 from public.payments o where o.request_id = r.id and o.orphan_reason is null and o.status in ('confirmed', 'refund_pending'))
     and (select financial_status from public.requests where id = r.id) = 'refund_pending' then
    perform app.fin_set(r.id, 'refunded', 'Estorno concluído pelo provedor');
    perform app.log(r.id, 'refunded', null);
  end if;
end $$;

-- Desfaz o reconhecimento (se houver), cancela o repasse ainda não pago e pede
-- o estorno de todos os pagamentos válidos do pedido.
create function app.reverse_and_refund(p_request uuid, p_note text, p_external boolean default false, p_reason text default 'finance') returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.requests;
  po public.payouts;
  v_held bigint;
  v_net bigint;
  v_rev bigint;
  pay record;
begin
  select * into r from public.requests where id = p_request for update;
  select * into po from public.payouts where request_id = r.id for update;
  if po.status = 'processing' then
    if not p_external then
      perform app.fail('payout_in_progress', 'O repasse deste pedido está sendo processado. Aguarde a conclusão para estornar.');
    end if;
    -- O cliente já foi estornado no provedor: não dá para recusar; alerta a equipe.
    perform app.finance_alert('Estorno com repasse em andamento', 'Um pagamento foi estornado enquanto o repasse estava em processamento. Confira o pedido.',
      '/hub/financeiro/repasses', 'refund-during-payout:' || po.id);
    perform app.log(r.id, 'refund_requested', null, p_note);
    return;
  end if;
  if r.recognized_journal is not null then
    select coalesce(sum(amount_cents), 0) into v_held from public.payments
    where request_id = r.id and orphan_reason is null and status in ('confirmed', 'refund_pending', 'refunded');
    v_net := app.cents(r.provider_net);
    v_rev := v_held - v_net;
    perform app.journal('Reversão do reconhecimento', jsonb_build_array(
        app.line(case when po.status = 'completed' then 'provider_receivable' else 'provider_payable' end, 'D', v_net),
        app.line('platform_revenue', 'D', greatest(v_rev, 0)),
        app.line('promotion_subsidy', 'C', greatest(-v_rev, 0)),
        app.line('customer_funds_held', 'C', v_held)),
      r.id, null, po.id);
  end if;
  if po.id is not null and po.status in ('scheduled', 'on_hold', 'failed') then
    update public.payouts set status = 'cancelled', cancelled_at = now(), updated_at = now() where id = po.id;
  end if;
  if r.financial_status <> 'refund_pending' then perform app.fin_set(r.id, 'refund_pending', p_note); end if;
  if not p_external then
    for pay in select id from public.payments where request_id = r.id and orphan_reason is null and status = 'confirmed' loop
      perform app.request_refund_payment(pay.id, p_reason, p_note);
    end loop;
  end if;
  perform app.log(r.id, 'refund_requested', null, p_note);
end $$;

-- Conclusão confirmada: reconhece receita e devido ao prestador e agenda o repasse.
create function app.confirm_completion(p_request uuid, p_by text, p_from_dispute boolean default false) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.requests;
  v_held bigint;
  v_net bigint;
  v_rev bigint;
  v_journal uuid;
  v_payout uuid;
begin
  select * into r from public.requests where id = p_request for update;
  if r.status <> 'completed' or r.recognized_journal is not null
     or r.financial_status <> (case when p_from_dispute then 'disputed' else 'service_completed' end) then
    perform app.fail('cannot_confirm', 'Este atendimento não está aguardando confirmação.');
  end if;
  select coalesce(sum(amount_cents), 0) into v_held from public.payments
  where request_id = r.id and orphan_reason is null and status = 'confirmed';
  v_net := app.cents(r.provider_net);
  v_rev := v_held - v_net;
  v_journal := app.journal('Conclusão confirmada: receita e repasse devido', jsonb_build_array(
      app.line('customer_funds_held', 'D', v_held),
      app.line('provider_payable', 'C', v_net),
      app.line('platform_revenue', 'C', greatest(v_rev, 0)),
      app.line('promotion_subsidy', 'D', greatest(-v_rev, 0))),
    r.id);
  update public.requests set completion_confirmed_at = now(), completion_confirmed_by = p_by, recognized_journal = v_journal where id = r.id;
  insert into public.payouts (request_id, provider_id, amount_cents, scheduled_for)
  values (r.id, r.provider_id, v_net, now() + make_interval(days => coalesce(r.payout_days_snapshot, (select payout_days from public.settings))))
  returning id into v_payout;
  perform app.fin_set(r.id, 'payout_scheduled', case p_by when 'auto' then 'Confirmação automática após o prazo' else 'Conclusão confirmada' end);
  perform app.log(r.id, 'payout_scheduled', null);
end $$;

-- -----------------------------------------------------------------------------
-- Repasses
-- -----------------------------------------------------------------------------
create function app.payout_done(p_payout uuid, p_fee_cents bigint default null) returns void
language plpgsql security definer set search_path = ''
as $$
declare po public.payouts; v_fin text;
begin
  select * into po from public.payouts where id = p_payout for update;
  if po.status = 'completed' then return; end if;
  update public.payouts set status = 'completed', completed_at = now(), fee_cents = coalesce(p_fee_cents, fee_cents),
    uncertain = false, final_failure = false, fail_reason = null, updated_at = now()
  where id = po.id;
  perform app.journal('Repasse ao prestador', jsonb_build_array(
      app.line('provider_payable', 'D', po.amount_cents),
      app.line('cash_gateway', 'C', po.amount_cents),
      app.line('gateway_fees', 'D', coalesce(p_fee_cents, 0)),
      app.line('cash_gateway', 'C', coalesce(p_fee_cents, 0))),
    po.request_id, null, po.id);
  select financial_status into v_fin from public.requests where id = po.request_id;
  if v_fin in ('payout_failed', 'payout_scheduled') then perform app.fin_set(po.request_id, 'payout_processing'); end if;
  perform app.fin_set(po.request_id, 'payout_completed', 'Transferência concluída');
  update public.requests set payout_at = now() where id = po.request_id;
  perform app.log(po.request_id, 'payout_completed', null);
end $$;

create function app.payout_failed(p_payout uuid, p_reason text, p_retryable boolean) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  po public.payouts;
  v_max integer;
  v_final boolean;
begin
  select * into po from public.payouts where id = p_payout for update;
  if po.status in ('completed', 'cancelled') then return; end if;
  select payout_max_attempts into v_max from public.settings;
  v_final := not p_retryable or po.attempts >= v_max;
  update public.payouts set status = 'failed', fail_reason = left(p_reason, 500), external_id = null, uncertain = false,
    claim_token = null, final_failure = v_final,
    next_attempt_at = case when v_final then null else now() + least(interval '12 hours', interval '5 minutes' * power(2, greatest(po.attempts - 1, 0))) end,
    updated_at = now()
  where id = po.id;
  if (select financial_status from public.requests where id = po.request_id) = 'payout_processing' then
    perform app.fin_set(po.request_id, 'payout_failed', left(p_reason, 300));
  end if;
  if v_final then
    perform app.log(po.request_id, 'payout_failed', null, left(p_reason, 300));
    perform app.finance_alert('Repasse com falha', 'O repasse do pedido falhou e precisa de ação: ' || left(p_reason, 200),
      '/hub/financeiro/repasses', 'payout-failed:' || po.id || ':' || po.attempts);
  end if;
end $$;

commit;

-- >>> 20261117000400_finance_flows.sql
-- =============================================================================
-- Zé do Carro — 08 Financeiro: fluxo do pedido (cliente e prestador)
-- Mudança de regra de negócio, justificada: o pagamento passa a ser feito
-- ANTES do atendimento. O pedido só é oferecido aos prestadores depois que o
-- provedor confirma o Pix; isso elimina inadimplência pós-serviço e pedidos
-- falsos, e permite reter o valor até a conclusão confirmada (repasse em 7 dias).
-- =============================================================================

-- Funções antigas substituídas: pagamento simulado pelo próprio cliente (fere a
-- regra de nunca confirmar pagamento pelo aplicativo do cliente) e confirmação
-- e repasse manuais sem rastreio contábil.
drop function public.pay_request(uuid);
drop function public.admin_confirm_payment(uuid);
drop function public.admin_mark_payout(uuid);
drop function app.mark_paid(uuid, public.user_role);
drop function public.admin_save_service(uuid, text, text, numeric, integer, boolean);
drop function public.admin_new_setup_code();

-- -----------------------------------------------------------------------------
-- Pedido em JSON: acrescenta preço detalhado, estado financeiro, repasse e disputa
-- -----------------------------------------------------------------------------
create or replace function app.request_json(p_id uuid, p_view text, p_lat double precision default null, p_lng double precision default null)
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
    'events', case when p_view = 'offer' then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object(
        'kind', ev.kind, 'actor', ev.actor, 'note', ev.note, 'at', ev.created_at) order by ev.id)
      from public.request_events ev where ev.request_id = r.id), '[]'::jsonb) end,
    'review', (select jsonb_build_object('rating', w.rating, 'comment', w.comment) from public.reviews w where w.request_id = r.id)
  ) || jsonb_build_object(
    'financial_status', r.financial_status,
    'discount_amount', r.discount_amount, 'fee_amount', r.fee_amount,
    'promotion_name', r.pricing_snapshot ->> 'promotion_name', 'region_name', r.pricing_snapshot ->> 'region_name',
    'payment_due_at', r.payment_due_at, 'completion_deadline', r.completion_deadline,
    'completion_confirmed_at', r.completion_confirmed_at, 'completion_confirmed_by', r.completion_confirmed_by,
    'extras', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'description', e.description,
        'price', e.price, 'status', e.status,
        'paid', exists (select 1 from public.payments pa where pa.extra_id = e.id and pa.orphan_reason is null
          and pa.status in ('confirmed', 'refund_pending', 'refunded'))) order by e.created_at)
      from public.request_extras e where e.request_id = r.id), '[]'::jsonb),
    'payout', case when p_view = 'offer' then null else (select jsonb_build_object('status', po.status,
        'scheduled_for', po.scheduled_for, 'completed_at', po.completed_at, 'amount', po.amount_cents / 100.0,
        'hold_reason', po.hold_reason) from public.payouts po where po.request_id = r.id) end,
    'dispute', case when p_view = 'offer' then null else (select jsonb_build_object('id', d.id, 'reason', d.reason,
        'opened_role', d.opened_role, 'status', d.status, 'created_at', d.created_at, 'resolution_note', d.resolution_note)
      from public.disputes d where d.request_id = r.id order by d.created_at desc limit 1) end)
  from public.requests r
  join public.services s on s.id = r.service_id
  join public.vehicles v on v.id = r.vehicle_id
  join public.profiles c on c.id = r.customer_id
  left join public.providers pr on pr.id = r.provider_id
  left join public.profiles pp on pp.id = r.provider_id
  where r.id = p_id
$$;

-- Pagamentos do pedido, como o cliente os vê (o QR Code só da cobrança em aberto).
create function app.customer_payments(p_request uuid) returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'extra_id', p.extra_id, 'method', p.method,
      'status', p.status, 'amount', p.amount_cents / 100.0,
      'pix_payload', case when p.status = 'pending' then p.pix_payload end,
      'pix_qr_image', case when p.status = 'pending' then p.pix_qr_image end,
      'pix_expires_at', p.pix_expires_at, 'claimed', coalesce(p.provider_status = 'claimed', false),
      'orphan_reason', p.orphan_reason, 'created_at', p.created_at, 'confirmed_at', p.confirmed_at,
      'refunded_at', p.refunded_at) order by p.created_at), '[]'::jsonb)
  from public.payments p where p.request_id = p_request
$$;

create or replace function public.my_access() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'user_id', auth.uid(),
    'profile', (select jsonb_build_object('id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'role', p.role)
                from public.profiles p where p.id = auth.uid()),
    'provider', (select jsonb_build_object('status', pr.status, 'online', pr.online, 'contract_ok', app.contract_ok(pr.id))
                 from public.providers pr where pr.id = auth.uid()),
    'staff', (select coalesce(jsonb_agg(s.role order by s.role), '[]'::jsonb) from public.staff_roles s
              join public.profiles p on p.id = s.user_id and p.role = 'hub_admin' where s.user_id = auth.uid()),
    'unread', (select count(*) from public.notifications n where n.user_id = auth.uid() and n.read_at is null))
$$;

-- =============================================================================
-- Cliente
-- =============================================================================
create or replace function public.list_services() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select case when auth.uid() is null then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'code', s.code, 'name', s.name, 'description', s.description, 'category_code', s.category_code,
    'category_name', c.name, 'base_price', s.base_price, 'est_minutes', s.est_minutes) order by c.sort, s.sort, s.name), '[]'::jsonb) end
  from public.services s left join public.service_categories c on c.code = s.category_code where s.active
$$;

-- Valor final antes de confirmar: preço da região, desconto e taxa, sem surpresas.
create function public.quote_service(p_service_id uuid, p_lat double precision default null, p_lng double precision default null) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_quote jsonb;
begin
  perform app.require_role('customer');
  v_quote := app.quote(p_service_id, p_lat, p_lng);
  if v_quote is null then perform app.fail('service_unavailable', 'Este serviço não está disponível.'); end if;
  return v_quote - 'promotion_id' - 'region_id';
end $$;

create or replace function public.create_request(
  p_service_id uuid, p_vehicle_id uuid, p_address text,
  p_lat double precision default null, p_lng double precision default null, p_notes text default ''
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('customer');
  v_quote jsonb;
  v_commission jsonb;
  v_pct numeric(5,2);
  v_list numeric(12,2);
  v_discount numeric(12,2);
  v_fee numeric(12,2);
  v_total numeric(12,2);
  v_commission_amount numeric(12,2);
  st public.settings;
  v_id uuid;
begin
  perform app.hit('create_request:' || v_uid, 10, 3600);
  v_quote := app.quote(p_service_id, p_lat, p_lng);
  if v_quote is null then perform app.fail('service_unavailable', 'Este serviço não está disponível.'); end if;
  if not exists (select 1 from public.vehicles where id = p_vehicle_id and customer_id = v_uid and not archived) then
    perform app.fail('vehicle_not_found', 'Escolha um dos seus veículos.');
  end if;
  if length(btrim(coalesce(p_address, ''))) < 5 then perform app.fail('invalid_address', 'Informe o endereço do atendimento.'); end if;
  if (select count(*) from public.requests where customer_id = v_uid and status not in ('completed', 'cancelled')) >= 3 then
    perform app.fail('too_many_requests', 'Você já tem pedidos em andamento. Conclua ou cancele um deles.');
  end if;
  select * into st from public.settings;
  v_list := (v_quote ->> 'list_price')::numeric;
  v_discount := (v_quote ->> 'discount')::numeric;
  v_fee := (v_quote ->> 'fee')::numeric;
  v_total := (v_quote ->> 'total')::numeric;
  if v_total < st.min_charge_amount then perform app.fail('below_minimum', 'O valor deste serviço está abaixo do mínimo para cobrança.'); end if;
  v_commission := app.commission_for(v_quote ->> 'category_code', null, now());
  v_pct := (v_commission ->> 'percent')::numeric;
  v_commission_amount := round(v_list * v_pct / 100, 2);
  insert into public.requests (customer_id, vehicle_id, service_id, status, address, lat, lng, notes,
    price, discount_amount, fee_amount, promotion_id, region_id, commission_percent, base_commission_percent, commission_rule_id,
    total, commission_amount, provider_net, pricing_snapshot, financial_status, payment_due_at)
  values (v_uid, p_vehicle_id, p_service_id, 'awaiting_payment', btrim(p_address), p_lat, p_lng, left(btrim(coalesce(p_notes, '')), 500),
    v_list, v_discount, v_fee, (v_quote ->> 'promotion_id')::uuid, (v_quote ->> 'region_id')::uuid,
    v_pct, v_pct, (v_commission ->> 'rule_id')::uuid,
    v_total, v_commission_amount, v_list - v_commission_amount, v_quote || jsonb_build_object('commission', v_commission),
    'pending_payment', now() + make_interval(mins => st.payment_window_minutes))
  returning id into v_id;
  perform app.log(v_id, 'created', 'customer');
  return v_id;
end $$;

create or replace function public.request_detail(p_id uuid) returns jsonb
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
  if r.customer_id = v_uid then
    return app.request_json(p_id, 'full') || jsonb_build_object('payments', app.customer_payments(p_id));
  end if;
  if v_role = 'hub_admin' and (app.is_staff(v_uid, 'admin') or app.is_staff(v_uid, 'finance')) then
    return app.request_json(p_id, 'full') || jsonb_build_object('payments', app.customer_payments(p_id) );
  end if;
  if r.provider_id = v_uid then
    select * into p from public.providers where id = v_uid;
    return app.request_json(p_id, 'full', p.last_lat, p.last_lng);
  end if;
  if v_role = 'provider' and r.status = 'searching' and app.can_take(v_uid, p_id) then
    select * into p from public.providers where id = v_uid;
    return app.request_json(p_id, 'offer', coalesce(p.last_lat, p.base_lat), coalesce(p.last_lng, p.base_lng)) || app.offer_terms(p_id, v_uid);
  end if;
  perform app.deny();
  return null;
end $$;

-- Cancelamento pelo cliente. Sem pagamento confirmado: encerra a cobrança. Com
-- pagamento confirmado e antes do início do serviço: estorno integral automático.
create or replace function public.cancel_request(p_id uuid, p_reason text default '') returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('customer');
  r public.requests;
  v_reason text := left(btrim(coalesce(p_reason, '')), 300);
begin
  select * into r from public.requests where id = p_id and customer_id = v_uid for update;
  if r.id is null then perform app.deny(); end if;
  if r.status = 'awaiting_payment' then
    update public.payments set status = 'cancelled', cancelled_at = now(), remote_cancel_pending = external_id is not null, updated_at = now()
    where request_id = r.id and status in ('creating', 'pending');
    update public.requests set status = 'cancelled', cancelled_at = now(), cancelled_by = 'customer', cancel_reason = v_reason where id = r.id;
    perform app.fin_set(r.id, 'cancelled', 'Cancelado pelo cliente antes do pagamento');
  elsif r.status in ('searching', 'accepted', 'en_route') then
    update public.requests set status = 'cancelled', cancelled_at = now(), cancelled_by = 'customer', cancel_reason = v_reason where id = r.id;
    perform app.reverse_and_refund(r.id, 'Cancelado pelo cliente antes do início do serviço', false, 'cancelled_before_service');
  else
    perform app.fail('cannot_cancel', 'Este pedido não pode mais ser cancelado pelo aplicativo. Fale com o suporte.');
  end if;
  perform app.log(p_id, 'cancelled', 'customer', nullif(v_reason, ''));
end $$;

create or replace function public.decide_extra(p_extra_id uuid, p_approve boolean) returns void
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

-- Forma de pagamento vigente (sem dados internos).
create or replace function public.payment_info() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'mode', s.payment_provider,
    'pix_key', case when s.payment_provider = 'manual' then s.pix_key end,
    'pix_holder', case when s.payment_provider = 'manual' then s.pix_holder end,
    'has_tax_id', exists (select 1 from public.payment_customers pc where pc.profile_id = auth.uid())) end
  from public.settings s
$$;

-- CPF/CNPJ para a cobrança. Validado (dígitos verificadores) e guardado à parte.
create function public.save_payment_tax_id(p_tax_id text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('customer');
  v_doc text := regexp_replace(coalesce(p_tax_id, ''), '[^0-9]', '', 'g');
begin
  perform app.hit('tax_id:' || v_uid, 10, 3600);
  if not (app.valid_cpf(v_doc) or app.valid_cnpj(v_doc)) then
    perform app.fail('invalid_tax_id', 'CPF ou CNPJ inválido. Confira os números.');
  end if;
  insert into public.payment_customers (profile_id, tax_id) values (v_uid, v_doc)
  on conflict (profile_id) do update set tax_id = excluded.tax_id,
    -- Documento novo: o cadastro no provedor é refeito na próxima cobrança.
    external_id = case when public.payment_customers.tax_id = excluded.tax_id then public.payment_customers.external_id end,
    updated_at = now();
end $$;

create function public.payment_profile() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('customer');
begin
  return (select jsonb_build_object('has_tax_id', pc.profile_id is not null,
      'tax_id_masked', case when pc.tax_id is null then null else '***.' || substr(pc.tax_id, 4, 3) || '.***-' || right(pc.tax_id, 2) end)
    from (select 1) x left join public.payment_customers pc on pc.profile_id = v_uid);
end $$;

-- Prepara a cobrança do pedido (ou de um adicional aprovado). Idempotente: se já
-- há cobrança válida em aberto, devolve a mesma. A criação no provedor é feita
-- pelo servidor do aplicativo, que registra o resultado com a chave secreta.
create function public.payment_start(p_request_id uuid, p_extra_id uuid default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('customer');
  r public.requests;
  e public.request_extras;
  st public.settings;
  open_p public.payments;
  v_amount bigint;
  v_due timestamptz;
  v_id uuid;
  v_key uuid;
  pc public.payment_customers;
  pf public.profiles;
  v_label text;
begin
  perform app.hit('payment_start:' || v_uid, 30, 600);
  select * into r from public.requests where id = p_request_id and customer_id = v_uid for update;
  if r.id is null then perform app.deny(); end if;
  select * into st from public.settings;
  if p_extra_id is null then
    if r.status <> 'awaiting_payment' or r.financial_status <> 'pending_payment' then
      perform app.fail('not_awaiting_payment', 'Este pedido não está aguardando pagamento.');
    end if;
    if r.payment_due_at < now() then perform app.fail('payment_window_closed', 'O prazo para pagar este pedido terminou. Faça um novo pedido.'); end if;
    v_amount := app.cents(r.price - r.discount_amount + r.fee_amount);
    v_due := r.payment_due_at;
    v_label := 'pedido nº ' || r.number;
  else
    select * into e from public.request_extras where id = p_extra_id and request_id = r.id;
    if e.id is null or e.status <> 'approved' or r.status <> 'in_progress' then
      perform app.fail('extra_not_payable', 'Este adicional não está aguardando pagamento.');
    end if;
    if exists (select 1 from public.payments where extra_id = e.id and orphan_reason is null and status in ('confirmed', 'refund_pending', 'refunded')) then
      perform app.fail('already_paid', 'Este adicional já foi pago.');
    end if;
    v_amount := app.cents(e.price);
    v_due := now() + make_interval(mins => st.payment_window_minutes);
    v_label := 'adicional do pedido nº ' || r.number;
  end if;

  select * into open_p from public.payments where request_id = r.id and extra_id is not distinct from p_extra_id
    and status in ('creating', 'pending') for update;
  if open_p.id is not null then
    if open_p.status = 'pending' and (open_p.pix_expires_at is null or open_p.pix_expires_at > now()) and open_p.amount_cents = v_amount then
      return jsonb_build_object('mode', case when open_p.method = 'pix_manual' then 'manual' else 'asaas' end, 'action', 'existing', 'payment_id', open_p.id);
    end if;
    if open_p.status = 'creating' and open_p.created_at > now() - interval '2 minutes' then
      return jsonb_build_object('mode', 'asaas', 'action', 'wait', 'payment_id', open_p.id);
    end if;
    update public.payments set status = case when status = 'creating' then 'failed' else 'expired' end,
      remote_cancel_pending = external_id is not null, last_error = 'Substituída por nova cobrança', updated_at = now()
    where id = open_p.id;
  end if;

  if st.payment_provider = 'manual' then
    if st.pix_key is null then perform app.fail('payment_unavailable', 'O pagamento ainda não foi configurado pela HUB.'); end if;
    insert into public.payments (request_id, extra_id, kind, method, status, amount_cents, due_at)
    values (r.id, p_extra_id, case when p_extra_id is null then 'service' else 'extra' end, 'pix_manual', 'pending', v_amount, v_due)
    returning id into v_id;
    return jsonb_build_object('mode', 'manual', 'action', 'existing', 'payment_id', v_id);
  end if;

  select * into pc from public.payment_customers where profile_id = v_uid;
  if pc.profile_id is null then perform app.fail('tax_id_required', 'Informe o CPF ou CNPJ para emitir a cobrança Pix.'); end if;
  select * into pf from public.profiles where id = v_uid;
  insert into public.payments (request_id, extra_id, kind, method, status, amount_cents, due_at)
  values (r.id, p_extra_id, case when p_extra_id is null then 'service' else 'extra' end, 'pix_asaas', 'creating', v_amount, v_due)
  returning id, attempt_key into v_id, v_key;
  return jsonb_build_object('mode', 'asaas', 'action', 'create', 'payment_id', v_id, 'attempt_key', v_key,
    'amount_cents', v_amount, 'description', 'Zé do Carro — ' || v_label,
    'due_date', to_char(v_due at time zone 'America/Fortaleza', 'YYYY-MM-DD'),
    'customer', jsonb_build_object('profile_id', v_uid, 'name', pf.full_name, 'tax_id', pc.tax_id, 'phone', pf.phone,
      'email', (select email from auth.users where id = v_uid), 'external_id', pc.external_id));
end $$;

-- Pix manual: o cliente AVISA que pagou. Isso não confirma nada; só a equipe
-- financeira confirma, com o identificador da transação.
create or replace function public.claim_payment(p_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('customer');
begin
  if (select payment_provider from public.settings) <> 'manual' then perform app.fail('not_manual', 'A confirmação deste pagamento é automática.'); end if;
  update public.payments p set provider_status = 'claimed', updated_at = now()
  from public.requests r
  where p.request_id = r.id and r.id = p_id and r.customer_id = v_uid and p.method = 'pix_manual' and p.status = 'pending'
    and p.provider_status is distinct from 'claimed';
  if not found then perform app.fail('cannot_pay', 'Não há pagamento aguardando aviso neste pedido.'); end if;
  update public.requests set payment_claimed_at = now() where id = p_id;
  perform app.log(p_id, 'payment_claimed', 'customer');
end $$;

create function public.confirm_completion(p_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('customer');
begin
  if not exists (select 1 from public.requests where id = p_id and customer_id = v_uid) then perform app.deny(); end if;
  perform app.confirm_completion(p_id, 'customer');
  perform app.log(p_id, 'completion_confirmed', 'customer');
end $$;

-- Disputa: trava o repasse até a decisão da equipe financeira.
create function public.open_dispute(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.uid();
  v_role public.user_role;
  r public.requests;
begin
  select role into v_role from public.profiles where id = v_uid;
  select * into r from public.requests where id = p_id for update;
  if r.id is null or not ((v_role = 'customer' and r.customer_id = v_uid) or (v_role = 'provider' and r.provider_id = v_uid)) then
    perform app.deny();
  end if;
  perform app.hit('dispute:' || v_uid, 5, 3600);
  if length(btrim(coalesce(p_reason, ''))) < 20 then perform app.fail('reason_required', 'Descreva o problema (ao menos 20 caracteres).'); end if;
  if r.financial_status not in ('service_completed', 'payout_scheduled', 'payout_failed') then
    perform app.fail('cannot_dispute', 'Não é possível abrir disputa neste momento. Fale com o suporte.');
  end if;
  insert into public.disputes (request_id, opened_by, opened_role, reason, previous_financial_status)
  values (r.id, v_uid, v_role::text, left(btrim(p_reason), 2000), r.financial_status);
  update public.payouts set status = 'on_hold', hold_reason = 'dispute', updated_at = now()
  where request_id = r.id and status in ('scheduled', 'failed');
  perform app.fin_set(r.id, 'disputed', 'Disputa aberta');
  perform app.log(r.id, 'dispute_opened', v_role, left(btrim(p_reason), 300));
end $$;

-- =============================================================================
-- Prestador
-- =============================================================================
create or replace function public.open_requests() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('provider');
  p public.providers;
begin
  select * into p from public.providers where id = v_uid;
  if not p.online then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(app.request_json(r.id, 'offer', coalesce(p.last_lat, p.base_lat), coalesce(p.last_lng, p.base_lng))
      || app.offer_terms(r.id, v_uid) order by r.created_at)
    from public.requests r where r.status = 'searching' and app.can_take(v_uid, r.id)), '[]'::jsonb);
end $$;

-- No aceite (a contratação), a comissão do prestador e o prazo de repasse ficam
-- registrados no pedido e não mudam mais.
create or replace function public.accept_request(p_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('provider');
  v_commission jsonb;
begin
  if not (select online from public.providers where id = v_uid) then
    perform app.fail('offline', 'Fique disponível para aceitar pedidos.');
  end if;
  if exists (select 1 from public.requests where provider_id = v_uid and status in ('accepted', 'en_route', 'in_progress')) then
    perform app.fail('busy', 'Conclua o atendimento em andamento antes de aceitar outro.');
  end if;
  if not app.can_take(v_uid, p_id) then perform app.fail('request_taken', 'Este pedido não está mais disponível.'); end if;
  v_commission := app.request_commission(p_id, v_uid);
  update public.requests set status = 'accepted', provider_id = v_uid, accepted_at = now(),
    commission_percent = (v_commission ->> 'percent')::numeric, commission_rule_id = (v_commission ->> 'rule_id')::uuid,
    payout_days_snapshot = (select payout_days from public.settings)
  where id = p_id and status = 'searching';
  if not found then perform app.fail('request_taken', 'Este pedido não está mais disponível.'); end if;
  perform app.recalc(p_id);
  perform app.log(p_id, 'accepted', 'provider');
end $$;

create or replace function public.advance_request(p_id uuid, p_to text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('provider');
  r public.requests;
begin
  select * into r from public.requests where id = p_id and provider_id = v_uid for update;
  if r.id is null then perform app.deny(); end if;
  if not ((r.status = 'accepted' and p_to = 'en_route') or (r.status = 'en_route' and p_to = 'in_progress')
       or (r.status = 'in_progress' and p_to = 'completed')) then
    perform app.fail('invalid_step', 'Esta etapa não está disponível agora.');
  end if;
  if r.financial_status not in ('payment_confirmed', 'service_in_progress') then
    perform app.fail('payment_not_confirmed', 'O pagamento deste pedido não está confirmado.');
  end if;
  if p_to = 'completed' and exists (select 1 from public.request_extras where request_id = p_id and status = 'proposed') then
    perform app.fail('extras_pending', 'Há um orçamento adicional aguardando a resposta do cliente.');
  end if;
  if p_to = 'completed' and exists (select 1 from public.request_extras e where e.request_id = p_id and e.status = 'approved'
      and not exists (select 1 from public.payments pa where pa.extra_id = e.id and pa.orphan_reason is null and pa.status = 'confirmed')) then
    perform app.fail('extra_unpaid', 'Há um adicional aprovado ainda não pago. Aguarde o pagamento ou cancele o adicional.');
  end if;
  update public.requests set status = p_to::public.request_status,
    started_at = case when p_to = 'in_progress' then now() else started_at end,
    completed_at = case when p_to = 'completed' then now() else completed_at end,
    completion_deadline = case when p_to = 'completed' then now() + make_interval(hours => (select confirm_hours from public.settings)) else completion_deadline end
  where id = p_id;
  if p_to = 'in_progress' then perform app.fin_set(p_id, 'service_in_progress'); end if;
  if p_to = 'completed' then perform app.fin_set(p_id, 'service_completed'); end if;
  perform app.log(p_id, p_to, 'provider');
end $$;

create or replace function public.withdraw_request(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('provider');
begin
  if length(btrim(coalesce(p_reason, ''))) < 10 then perform app.fail('reason_required', 'Explique o motivo (ao menos 10 caracteres).'); end if;
  update public.requests set status = 'searching', provider_id = null, accepted_at = null,
    commission_percent = base_commission_percent, commission_rule_id = (pricing_snapshot -> 'commission' ->> 'rule_id')::uuid,
    payout_days_snapshot = null
  where id = p_id and provider_id = v_uid and status in ('accepted', 'en_route');
  if not found then perform app.fail('cannot_withdraw', 'Não é possível desistir depois de iniciar o serviço. Fale com o suporte.'); end if;
  perform app.recalc(p_id);
  insert into public.request_declines (request_id, provider_id) values (p_id, v_uid) on conflict do nothing;
  perform app.log(p_id, 'withdrawn', 'provider', left(btrim(p_reason), 300));
end $$;

-- Adicional aprovado que não será feito (por exemplo, o cliente não pagou).
create function public.cancel_extra(p_extra_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('provider');
  e public.request_extras;
begin
  select e2.* into e from public.request_extras e2 join public.requests r on r.id = e2.request_id
  where e2.id = p_extra_id and r.provider_id = v_uid and r.status = 'in_progress' for update of e2;
  if e.id is null then perform app.deny(); end if;
  if e.status not in ('proposed', 'approved') then perform app.fail('extra_closed', 'Este adicional já foi encerrado.'); end if;
  if exists (select 1 from public.payments where extra_id = e.id and orphan_reason is null and status = 'confirmed') then
    perform app.fail('extra_paid', 'Este adicional já foi pago e precisa ser feito. Fale com o suporte se houver problema.');
  end if;
  update public.request_extras set status = 'cancelled', decided_at = now() where id = e.id;
  update public.payments set status = 'cancelled', cancelled_at = now(), remote_cancel_pending = external_id is not null, updated_at = now()
  where extra_id = e.id and status in ('creating', 'pending');
  perform app.recalc(e.request_id);
  perform app.log(e.request_id, 'extra_cancelled', 'provider', e.description);
end $$;

-- Conta Pix de recebimento: sempre no CPF/CNPJ do credenciamento; passa por
-- conferência da equipe financeira e por carência antes do primeiro repasse.
create function public.save_payment_account(p_pix_key_type text, p_pix_key text, p_holder_name text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('provider');
  pr public.providers;
  v_key text := btrim(coalesce(p_pix_key, ''));
begin
  perform app.hit('payment_account:' || v_uid, 3, 86400);
  select * into pr from public.providers where id = v_uid;
  if pr.doc_number is null or pr.status in ('draft', 'closed') then
    perform app.fail('apply_first', 'Envie primeiro os dados do credenciamento.');
  end if;
  if p_pix_key_type not in ('CPF', 'CNPJ', 'EMAIL', 'PHONE', 'EVP') then perform app.fail('invalid_key_type', 'Escolha o tipo da chave Pix.'); end if;
  if p_pix_key_type in ('CPF', 'CNPJ') then v_key := regexp_replace(v_key, '[^0-9]', '', 'g'); end if;
  if p_pix_key_type = 'PHONE' then
    v_key := regexp_replace(v_key, '[^0-9]', '', 'g');
    if v_key !~ '^(55)?[1-9][0-9]{9,10}$' then perform app.fail('invalid_key', 'Informe o celular com DDD.'); end if;
    v_key := '+' || case when v_key ~ '^55' and length(v_key) > 11 then v_key else '55' || v_key end;
  end if;
  if (p_pix_key_type = 'CPF' and not app.valid_cpf(v_key)) or (p_pix_key_type = 'CNPJ' and not app.valid_cnpj(v_key))
     or (p_pix_key_type = 'EMAIL' and v_key !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
     or (p_pix_key_type = 'EVP' and v_key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    perform app.fail('invalid_key', 'Chave Pix inválida para o tipo escolhido.');
  end if;
  if p_pix_key_type in ('CPF', 'CNPJ') and v_key <> pr.doc_number then
    perform app.fail('key_not_owner', 'A chave CPF/CNPJ precisa ser a mesma do seu credenciamento.');
  end if;
  if length(btrim(coalesce(p_holder_name, ''))) < 3 then perform app.fail('invalid_name', 'Informe o nome do titular da conta.'); end if;
  update public.provider_payment_accounts set status = 'replaced' where provider_id = v_uid and status = 'pending_review';
  insert into public.provider_payment_accounts (provider_id, pix_key_type, pix_key, holder_name, holder_doc)
  values (v_uid, p_pix_key_type, case when p_pix_key_type = 'EMAIL' then lower(v_key) else v_key end, btrim(p_holder_name), pr.doc_number);
  perform app.notify(v_uid, 'Conta de recebimento enviada', 'Sua nova chave Pix será conferida pela HUB. Se não foi você, fale com o suporte agora.', '/prestador/ganhos');
  perform app.email(v_uid, 'conta_pix_alterada', jsonb_build_object('key_type', p_pix_key_type, 'url', '/prestador/ganhos'),
    'pix-account:' || v_uid || ':' || extract(epoch from now())::bigint);
  perform app.notify_staff('finance', 'Conta Pix para conferir', coalesce(pr.legal_name, 'Prestador') || ' cadastrou uma conta de recebimento.', '/hub/financeiro/contas');
end $$;

create function public.provider_finance() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('provider');
begin
  return jsonb_build_object(
    'summary', (select jsonb_build_object(
        'scheduled', coalesce(sum(amount_cents) filter (where status = 'scheduled'), 0) / 100.0,
        'on_hold', coalesce(sum(amount_cents) filter (where status = 'on_hold'), 0) / 100.0,
        'processing', coalesce(sum(amount_cents) filter (where status in ('processing', 'failed')), 0) / 100.0,
        'received', coalesce(sum(amount_cents) filter (where status = 'completed'), 0) / 100.0)
      from public.payouts where provider_id = v_uid),
    'awaiting_confirmation', (select coalesce(sum(provider_net), 0) from public.requests
      where provider_id = v_uid and financial_status in ('service_completed', 'disputed')),
    'account', (select jsonb_build_object('pix_key_type', a.pix_key_type,
        'pix_key_masked', case when length(a.pix_key) > 6 then left(a.pix_key, 3) || repeat('•', 5) || right(a.pix_key, 3) else '•••' end,
        'holder_name', a.holder_name, 'usable_from', a.usable_from)
      from public.provider_payment_accounts a where a.provider_id = v_uid and a.status = 'active'),
    'pending_account', (select jsonb_build_object('pix_key_type', a.pix_key_type, 'created_at', a.created_at)
      from public.provider_payment_accounts a where a.provider_id = v_uid and a.status = 'pending_review'),
    'rejected_account', (select jsonb_build_object('review_note', a.review_note, 'reviewed_at', a.reviewed_at)
      from public.provider_payment_accounts a where a.provider_id = v_uid and a.status = 'rejected'
        and not exists (select 1 from public.provider_payment_accounts b where b.provider_id = v_uid and b.created_at > a.created_at)
      order by a.created_at desc limit 1),
    'payouts', coalesce((select jsonb_agg(jsonb_build_object('id', po.id, 'request_id', po.request_id, 'number', r.number,
        'service', s.name, 'amount', po.amount_cents / 100.0, 'status', po.status, 'scheduled_for', po.scheduled_for,
        'completed_at', po.completed_at, 'hold_reason', po.hold_reason, 'final_failure', po.final_failure) order by po.created_at desc)
      from (select * from public.payouts where provider_id = v_uid order by created_at desc limit 60) po
      join public.requests r on r.id = po.request_id join public.services s on s.id = r.service_id), '[]'::jsonb));
end $$;

create or replace function public.provider_jobs() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('provider');
begin
  return jsonb_build_object(
    'summary', (select jsonb_build_object(
        'completed', count(*) filter (where status = 'completed'),
        'net_total', coalesce(sum(provider_net) filter (where status = 'completed' and financial_status <> 'refunded'), 0),
        'to_receive', coalesce(sum(provider_net) filter (where financial_status in ('payout_scheduled', 'payout_processing', 'payout_failed')), 0),
        'received', coalesce(sum(provider_net) filter (where financial_status = 'payout_completed'), 0),
        'awaiting_payment', coalesce(sum(provider_net) filter (where financial_status in ('service_completed', 'disputed')), 0))
      from public.requests where provider_id = v_uid),
    'jobs', coalesce((select jsonb_agg(app.request_json(r.id, 'full') order by r.created_at desc)
      from (select id, created_at from public.requests where provider_id = v_uid order by created_at desc limit 50) r), '[]'::jsonb));
end $$;

-- =============================================================================
-- Avisos: novos eventos financeiros (substitui o gatilho anterior)
-- =============================================================================
create or replace function app.on_request_event() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  r public.requests;
  v_service text;
  v_provider text;
  v_customer_url text;
  v_provider_url text;
  v_key text := 'req:' || new.request_id || ':' || new.kind || ':' || new.id;
  v_data jsonb;
  po public.payouts;
  p record;
begin
  select * into r from public.requests where id = new.request_id;
  select name into v_service from public.services where id = r.service_id;
  select full_name into v_provider from public.profiles where id = r.provider_id;
  select * into po from public.payouts where request_id = r.id;
  v_customer_url := '/cliente/pedidos/' || r.id;
  v_provider_url := '/prestador/pedidos/' || r.id;
  v_data := jsonb_build_object('number', r.number, 'service', v_service, 'total', app.brl(r.total),
    'provider_net', app.brl(r.provider_net), 'url_customer', v_customer_url, 'url_provider', v_provider_url);

  if new.kind = 'withdrawn' then
    perform app.notify(r.customer_id, 'Buscando outro prestador', 'O prestador não poderá atender seu pedido de ' || v_service || '. Já estamos procurando outro.', v_customer_url);
  end if;
  if new.kind in ('paid', 'withdrawn') then
    -- Oferta aos prestadores disponíveis e habilitados na região (só depois do pagamento).
    for p in select pr.id from public.providers pr where pr.online and app.can_take(pr.id, r.id) loop
      perform app.notify(p.id, 'Novo pedido: ' || v_service,
        'Você recebe ' || app.brl((app.offer_terms(r.id, p.id) ->> 'provider_net')::numeric) || ' · ' || r.address, v_provider_url);
    end loop;
  end if;

  if new.kind = 'paid' then
    perform app.notify(r.customer_id, 'Pagamento confirmado', 'Recebemos o Pix de ' || app.brl(r.total) || '. Estamos chamando um prestador.', v_customer_url);
    perform app.email(r.customer_id, 'pagamento_confirmado', v_data, v_key);
  elsif new.kind = 'payment_expired' then
    perform app.notify(r.customer_id, 'Pedido encerrado', 'O pagamento do pedido nº ' || r.number || ' não foi confirmado no prazo. Faça um novo pedido quando quiser.', v_customer_url);
  elsif new.kind = 'accepted' then
    perform app.notify(r.customer_id, 'Prestador confirmado', v_provider || ' aceitou seu pedido de ' || v_service || '.', v_customer_url);
  elsif new.kind = 'en_route' then
    perform app.notify(r.customer_id, 'Prestador a caminho', v_provider || ' está indo até o seu carro.', v_customer_url);
  elsif new.kind = 'in_progress' then
    perform app.notify(r.customer_id, 'Serviço iniciado', v_provider || ' começou o serviço de ' || v_service || '.', v_customer_url);
  elsif new.kind = 'extra_proposed' then
    perform app.notify(r.customer_id, 'Orçamento adicional', 'O prestador enviou um orçamento: ' || coalesce(new.note, '') || '. Aprove ou recuse no aplicativo.', v_customer_url);
  elsif new.kind = 'extra_approved' then
    perform app.notify(r.provider_id, 'Adicional aprovado', 'O cliente aprovou o adicional do pedido nº ' || r.number || '. Aguarde o pagamento antes de executar.', v_provider_url);
    perform app.notify(r.customer_id, 'Pague o adicional', 'Pague o adicional aprovado pelo Pix para o prestador continuar.', v_customer_url);
  elsif new.kind = 'extra_rejected' then
    perform app.notify(r.provider_id, 'Adicional recusado', 'O cliente recusou o adicional do pedido nº ' || r.number || '.', v_provider_url);
  elsif new.kind = 'extra_paid' then
    perform app.notify(r.provider_id, 'Adicional pago', 'O pagamento do adicional do pedido nº ' || r.number || ' foi confirmado.', v_provider_url);
  elsif new.kind = 'extra_cancelled' then
    perform app.notify(r.customer_id, 'Adicional cancelado', 'O prestador cancelou o adicional: ' || coalesce(new.note, '') || '.', v_customer_url);
  elsif new.kind = 'completed' then
    perform app.notify(r.customer_id, 'Serviço concluído', 'Confirme o serviço ou conte se houve problema até ' ||
      to_char(r.completion_deadline at time zone 'America/Fortaleza', 'DD/MM "às" HH24:MI') || '.', v_customer_url);
    perform app.email(r.customer_id, 'servico_concluido', v_data || jsonb_build_object('deadline',
      to_char(r.completion_deadline at time zone 'America/Fortaleza', 'DD/MM/YYYY "às" HH24:MI')), v_key);
  elsif new.kind = 'payout_scheduled' then
    perform app.notify(r.provider_id, 'Repasse agendado', 'Repasse de ' || app.brl(r.provider_net) || ' previsto para ' ||
      to_char(po.scheduled_for at time zone 'America/Fortaleza', 'DD/MM') || '.', v_provider_url);
    perform app.email(r.provider_id, 'repasse_agendado', v_data || jsonb_build_object('date',
      to_char(po.scheduled_for at time zone 'America/Fortaleza', 'DD/MM/YYYY')), v_key);
  elsif new.kind = 'payout_completed' then
    perform app.notify(r.provider_id, 'Repasse realizado', 'Transferimos ' || app.brl(r.provider_net) || ' do pedido nº ' || r.number || '.', v_provider_url);
    perform app.email(r.provider_id, 'repasse_realizado', v_data, v_key);
  elsif new.kind = 'payout_failed' then
    perform app.notify(r.provider_id, 'Repasse não concluído', 'Não conseguimos transferir o repasse do pedido nº ' || r.number || '. A HUB vai entrar em contato.', '/prestador/ganhos');
    perform app.email(r.provider_id, 'repasse_falhou', v_data, v_key);
  elsif new.kind = 'payout_on_hold' then
    perform app.notify(r.provider_id, 'Cadastre sua conta Pix', 'O repasse do pedido nº ' || r.number || ' está pronto, mas falta uma conta Pix conferida.', '/prestador/ganhos');
  elsif new.kind = 'cancelled' and r.provider_id is not null then
    perform app.notify(r.provider_id, 'Pedido cancelado', 'O cliente cancelou o pedido nº ' || r.number || ' (' || v_service || ').', v_provider_url);
  elsif new.kind = 'refund_requested' then
    perform app.notify(r.customer_id, 'Estorno solicitado', 'O valor pago no pedido nº ' || r.number || ' será devolvido para a sua conta.', v_customer_url);
  elsif new.kind = 'refunded' then
    perform app.notify(r.customer_id, 'Estorno concluído', 'Devolvemos o valor pago no pedido nº ' || r.number || '.', v_customer_url);
    perform app.email(r.customer_id, 'estorno_realizado', v_data, v_key);
  elsif new.kind = 'payment_claimed' then
    perform app.notify_staff('finance', 'Pagamento a confirmar', 'O cliente informou o Pix de ' || app.brl(r.total) || ' do pedido nº ' || r.number || '.', '/hub/financeiro/pagamentos');
  elsif new.kind = 'payment_orphan' then
    perform app.finance_alert('Pagamento a estornar', 'Pagamento do pedido nº ' || r.number || ' recebido fora do fluxo (' || coalesce(new.note, '') || '). O estorno foi solicitado.',
      '/hub/financeiro/pagamentos', v_key);
  elsif new.kind = 'dispute_opened' then
    perform app.finance_alert('Disputa aberta', 'Pedido nº ' || r.number || ': ' || coalesce(new.note, ''), '/hub/financeiro/disputas', v_key);
    if new.actor = 'customer' and r.provider_id is not null then
      perform app.notify(r.provider_id, 'Disputa aberta', 'O cliente relatou um problema no pedido nº ' || r.number || '. O repasse fica retido até a análise.', v_provider_url);
    end if;
  elsif new.kind = 'dispute_resolved' then
    perform app.notify(r.customer_id, 'Disputa analisada', 'A HUB registrou a decisão sobre o pedido nº ' || r.number || '.', v_customer_url);
    perform app.notify(r.provider_id, 'Disputa analisada', 'A HUB registrou a decisão sobre o pedido nº ' || r.number || '.', v_provider_url);
  elsif new.kind = 'completion_confirmed' and r.provider_id is not null then
    perform app.notify(r.provider_id, 'Serviço confirmado', 'O cliente confirmou o serviço do pedido nº ' || r.number || '.', v_provider_url);
  end if;
  return new;
end $$;

commit;

-- >>> 20261117000500_finance_operations.sql
-- =============================================================================
-- Zé do Carro — 09 Financeiro: integração (só servidor), equipe financeira e
-- administração comercial
-- =============================================================================

-- =============================================================================
-- Servidor do aplicativo (chave secreta, papel service_role)
-- =============================================================================
create function public.payment_customer_linked(p_profile_id uuid, p_external_id text) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_service_role();
  update public.payment_customers set external_id = p_external_id, updated_at = now() where profile_id = p_profile_id;
end $$;

create function public.payment_charge_created(p_payment_id uuid, p_external_id text, p_status text,
  p_pix_payload text, p_pix_qr_image text, p_pix_expires_at timestamptz) returns void
language plpgsql security definer set search_path = ''
as $$
declare p public.payments;
begin
  perform app.require_service_role();
  select * into p from public.payments where id = p_payment_id for update;
  if p.id is null then perform app.fail('not_found', 'Pagamento não encontrado.'); end if;
  if p.external_id is not null and p.external_id <> p_external_id then
    perform app.fail('external_conflict', 'O pagamento já tem outra cobrança vinculada.');
  end if;
  update public.payments set external_id = p_external_id, provider_status = p_status,
    pix_payload = p_pix_payload, pix_qr_image = p_pix_qr_image, pix_expires_at = p_pix_expires_at,
    status = case when status = 'creating' then 'pending' else status end,
    -- Cancelado enquanto a cobrança era criada: ela precisa ser removida no provedor.
    remote_cancel_pending = status in ('cancelled', 'expired', 'failed'),
    last_synced_at = now(), updated_at = now()
  where id = p.id;
end $$;

create function public.payment_charge_failed(p_payment_id uuid, p_error text) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_service_role();
  update public.payments set status = 'failed', last_error = left(p_error, 500), updated_at = now()
  where id = p_payment_id and status = 'creating';
end $$;

-- Aplica o estado OFICIAL de uma cobrança, consultado na API do provedor. É
-- idempotente e só avança: eventos repetidos ou fora de ordem não regridem nada.
create function public.payment_sync(p_external_id text, p_external_reference text, p_status text,
  p_value_cents bigint, p_net_cents bigint, p_deleted boolean default false) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  p public.payments;
  v_target text;
  v_result text := 'noop';
begin
  perform app.require_service_role();
  select * into p from public.payments where external_id = p_external_id for update;
  if p.id is null and coalesce(p_external_reference, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into p from public.payments where attempt_key = p_external_reference::uuid and external_id is null for update;
    if p.id is not null then update public.payments set external_id = p_external_id where id = p.id; end if;
  end if;
  if p.id is null then return jsonb_build_object('result', 'unknown'); end if;

  update public.payments set provider_status = case when provider_status = 'claimed' then provider_status else p_status end,
    last_synced_at = now(), updated_at = now() where id = p.id;
  v_target := case
    when p_status in ('RECEIVED', 'CONFIRMED', 'RECEIVED_IN_CASH') then 'confirmed'
    when p_status = 'REFUNDED' then 'refunded'
    when p_status in ('REFUND_REQUESTED', 'REFUND_IN_PROGRESS') then 'refund_pending'
    when coalesce(p_deleted, false) then 'cancelled'
    when p_status = 'OVERDUE' then 'expired'
    when p_status = 'PENDING' then 'pending'
    else null end;

  if v_target is null then
    perform app.finance_alert('Situação de pagamento não tratada', 'O provedor informou a situação ' || coalesce(p_status, '?') ||
      ' para um pagamento. Confira manualmente.', '/hub/financeiro/conciliacao', 'unhandled:' || p.id || ':' || coalesce(p_status, ''));
    return jsonb_build_object('result', 'unhandled', 'payment_id', p.id);
  end if;

  if v_target in ('confirmed', 'refund_pending', 'refunded') and p.status in ('creating', 'pending', 'expired', 'cancelled', 'failed') then
    v_result := app.apply_confirmed(p.id, p_value_cents, p_net_cents);
    select * into p from public.payments where id = p.id;
  end if;
  if v_target = 'refunded' and p.status in ('confirmed', 'refund_pending') then
    perform app.apply_refunded(p.id);
    v_result := 'refunded';
  elsif v_target in ('expired', 'cancelled') and p.status in ('creating', 'pending') then
    update public.payments set status = v_target, cancelled_at = now(),
      remote_cancel_pending = (v_target = 'expired'), updated_at = now() where id = p.id;
    v_result := v_target;
  end if;
  return jsonb_build_object('result', v_result, 'payment_id', p.id);
end $$;

-- Pagamentos a conferir no provedor (webhook perdido, criação interrompida,
-- estorno em andamento) e cobranças a remover no provedor.
create function public.payments_to_reconcile(p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_service_role();
  return coalesce((select jsonb_agg(jsonb_build_object('payment_id', p.id, 'external_id', p.external_id,
      'attempt_key', p.attempt_key, 'status', p.status, 'remote_cancel', p.remote_cancel_pending))
    from (select * from public.payments p
      where p.method = 'pix_asaas' and (
        (p.status in ('pending', 'refund_pending') and p.external_id is not null and p.created_at < now() - interval '1 minute'
          and (p.last_synced_at is null or p.last_synced_at < now() - interval '3 minutes'))
        or (p.status = 'creating' and p.created_at < now() - interval '3 minutes')
        or (p.remote_cancel_pending and p.external_id is not null))
      order by p.created_at limit greatest(1, least(p_limit, 200))) p), '[]'::jsonb);
end $$;

create function public.payment_remote_cancelled(p_payment_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_service_role();
  update public.payments set remote_cancel_pending = false, updated_at = now() where id = p_payment_id;
end $$;

-- Idempotência de webhook pelo id do evento. Repetição de evento já processado
-- é reconhecida e não reprocessa.
create function public.webhook_record(p_provider text, p_event_id text, p_event_type text, p_resource_id text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare w public.webhook_events;
begin
  perform app.require_service_role();
  insert into public.webhook_events (provider, event_id, event_type, resource_id, payload)
  values (p_provider, p_event_id, p_event_type, p_resource_id, p_payload)
  on conflict (provider, event_id) do nothing
  returning * into w;
  if w.id is not null then return jsonb_build_object('id', w.id, 'duplicate', false); end if;
  select * into w from public.webhook_events where provider = p_provider and event_id = p_event_id;
  return jsonb_build_object('id', w.id, 'duplicate', w.status in ('processed', 'ignored'));
end $$;

create function public.webhook_done(p_id bigint, p_status text, p_error text default null) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_service_role();
  if p_status not in ('processed', 'ignored', 'failed') then perform app.fail('invalid_status', 'Situação inválida.'); end if;
  update public.webhook_events set status = p_status, attempts = attempts + 1, last_error = left(p_error, 500),
    processed_at = case when p_status <> 'failed' then now() end
  where id = p_id;
end $$;

create function public.webhooks_to_retry(p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_service_role();
  return coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'event_type', w.event_type, 'resource_id', w.resource_id, 'payload', w.payload))
    from (select * from public.webhook_events where status in ('received', 'failed') and attempts < 10
      and received_at < now() - interval '1 minute' order by id limit greatest(1, least(p_limit, 200))) w), '[]'::jsonb);
end $$;

-- Estornos a enviar ao provedor.
create function public.refund_claim(p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_result jsonb;
begin
  perform app.require_service_role();
  with picked as (
    select f.id from public.refunds f join public.payments p on p.id = f.payment_id
    where f.status = 'requested' and f.next_attempt_at <= now() and p.method = 'pix_asaas' and p.external_id is not null
    order by f.created_at limit greatest(1, least(p_limit, 100)) for update of f skip locked
  ), claimed as (
    update public.refunds f set status = 'processing', attempts = f.attempts + 1, processed_at = now()
    from picked where f.id = picked.id returning f.*
  )
  select coalesce(jsonb_agg(jsonb_build_object('refund_id', c.id, 'payment_id', c.payment_id, 'external_id', p.external_id,
      'amount_cents', c.amount_cents, 'reason', c.reason)), '[]'::jsonb) into v_result
  from claimed c join public.payments p on p.id = c.payment_id;
  return v_result;
end $$;

create function public.refund_result(p_refund_id uuid, p_ok boolean, p_error text default null, p_retryable boolean default true) returns void
language plpgsql security definer set search_path = ''
as $$
declare f public.refunds;
begin
  perform app.require_service_role();
  select * into f from public.refunds where id = p_refund_id for update;
  if f.id is null or f.status <> 'processing' then return; end if;
  if p_ok then
    update public.refunds set external_status = 'requested', last_error = null where id = f.id;
  elsif p_retryable and f.attempts < 5 then
    update public.refunds set status = 'requested', last_error = left(p_error, 500),
      next_attempt_at = now() + interval '5 minutes' * power(2, f.attempts - 1) where id = f.id;
  else
    update public.refunds set status = 'failed', last_error = left(p_error, 500) where id = f.id;
    perform app.finance_alert('Estorno não concluído', 'O provedor recusou um estorno: ' || left(coalesce(p_error, ''), 200),
      '/hub/financeiro/pagamentos', 'refund-failed:' || f.id);
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- Repasses: reserva, resultado da transferência e conciliação
-- -----------------------------------------------------------------------------
-- Reserva os repasses vencidos. FOR UPDATE SKIP LOCKED + troca de estado na
-- mesma transação: dois processos nunca pegam o mesmo repasse.
create function public.payout_claim(p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_result jsonb := '[]'::jsonb;
  po record;
  v_token uuid;
  v_acc public.provider_payment_accounts;
begin
  perform app.require_service_role();
  if (select payout_mode from public.settings) <> 'asaas' then return v_result; end if;

  -- Sem conta Pix conferida: o repasse espera (e o prestador é avisado uma vez).
  for po in
    update public.payouts p set status = 'on_hold', hold_reason = 'no_account', updated_at = now()
    where p.status = 'scheduled' and p.scheduled_for <= now()
      and not exists (select 1 from public.provider_payment_accounts a where a.provider_id = p.provider_id and a.status = 'active')
    returning p.request_id
  loop
    perform app.log(po.request_id, 'payout_on_hold', null);
  end loop;

  for po in
    select p.* from public.payouts p join public.requests r on r.id = p.request_id
    where ((p.status = 'scheduled' and p.scheduled_for <= now())
        or (p.status = 'failed' and not p.final_failure and p.next_attempt_at <= now()))
      and r.financial_status in ('payout_scheduled', 'payout_failed')
      and not exists (select 1 from public.disputes d where d.request_id = p.request_id and d.status = 'open')
      and exists (select 1 from public.provider_payment_accounts a where a.provider_id = p.provider_id and a.status = 'active'
        and a.usable_from <= now())
    order by p.scheduled_for
    limit greatest(1, least(p_limit, 100))
    for update of p skip locked
  loop
    select * into v_acc from public.provider_payment_accounts where provider_id = po.provider_id and status = 'active';
    v_token := gen_random_uuid();
    update public.payouts set status = 'processing', claim_token = v_token, claimed_at = now(), attempts = attempts + 1,
      account_id = v_acc.id, pix_key_type = v_acc.pix_key_type, pix_key = v_acc.pix_key, uncertain = false, external_id = null, updated_at = now()
    where id = po.id;
    insert into public.payout_attempts (payout_id, attempt) values (po.id, po.attempts + 1);
    perform app.fin_set(po.request_id, 'payout_processing', 'Transferência iniciada');
    v_result := v_result || jsonb_build_array(jsonb_build_object('payout_id', po.id, 'claim_token', v_token,
      'amount_cents', po.amount_cents, 'pix_key', v_acc.pix_key, 'pix_key_type', v_acc.pix_key_type,
      'description', 'Repasse Zé do Carro — pedido nº ' || (select number from public.requests where id = po.request_id)));
  end loop;
  return v_result;
end $$;

create function public.payout_transfer_created(p_payout_id uuid, p_claim_token uuid, p_external_id text, p_status text,
  p_fee_cents bigint default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare po public.payouts;
begin
  perform app.require_service_role();
  select * into po from public.payouts where id = p_payout_id for update;
  if po.id is null or po.status <> 'processing' or po.claim_token is distinct from p_claim_token then
    perform app.finance_alert('Resposta de transferência fora de hora', 'Uma transferência foi criada para um repasse que não estava reservado. Confira no provedor.',
      '/hub/financeiro/repasses', 'stale-transfer:' || p_external_id);
    return jsonb_build_object('result', 'stale');
  end if;
  if po.external_id is not null and po.external_id <> p_external_id then
    update public.payouts set uncertain = true, fail_reason = 'Duas transferências para o mesmo repasse', updated_at = now() where id = po.id;
    perform app.finance_alert('Possível repasse em dobro', 'Duas transferências foram criadas para o mesmo repasse. Cancele uma delas no provedor.',
      '/hub/financeiro/repasses', 'double:' || po.id);
    return jsonb_build_object('result', 'conflict');
  end if;
  update public.payouts set external_id = p_external_id, external_status = p_status, updated_at = now() where id = po.id;
  update public.payout_attempts set finished_at = now(), outcome = 'created', external_id = p_external_id
  where payout_id = po.id and attempt = po.attempts;
  if p_status = 'DONE' then
    perform app.payout_done(po.id, p_fee_cents);
  elsif p_status in ('FAILED', 'CANCELLED') then
    perform app.payout_failed(po.id, 'Transferência ' || p_status, true);
  end if;
  return jsonb_build_object('result', 'ok');
end $$;

-- Falha ao chamar o provedor. p_uncertain: sem resposta (tempo esgotado, erro
-- de rede depois do envio): pode ter sido criada, então NÃO se tenta de novo
-- até a conciliação decidir.
create function public.payout_attempt_failed(p_payout_id uuid, p_claim_token uuid, p_error text, p_retryable boolean, p_uncertain boolean) returns void
language plpgsql security definer set search_path = ''
as $$
declare po public.payouts;
begin
  perform app.require_service_role();
  select * into po from public.payouts where id = p_payout_id for update;
  if po.id is null or po.status <> 'processing' or po.claim_token is distinct from p_claim_token then return; end if;
  update public.payout_attempts set finished_at = now(), outcome = case when p_uncertain then 'uncertain' else 'failed' end, error = left(p_error, 500)
  where payout_id = po.id and attempt = po.attempts;
  if p_uncertain then
    update public.payouts set uncertain = true, fail_reason = left(p_error, 500), updated_at = now() where id = po.id;
    perform app.finance_alert('Repasse sem confirmação', 'Não houve resposta do provedor ao criar uma transferência. O sistema vai conciliar antes de tentar de novo.',
      '/hub/financeiro/repasses', 'uncertain:' || po.id || ':' || po.attempts);
  else
    perform app.payout_failed(po.id, p_error, p_retryable);
  end if;
end $$;

-- Estado oficial de uma transferência (webhook TRANSFER_* ou consulta).
create function public.payout_sync_transfer(p_external_id text, p_external_reference text, p_status text,
  p_fail_reason text default null, p_fee_cents bigint default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  po public.payouts;
  v_historic uuid;
begin
  perform app.require_service_role();
  select * into po from public.payouts where external_id = p_external_id for update;
  if po.id is null then
    select payout_id into v_historic from public.payout_attempts where external_id = p_external_id order by id desc limit 1;
    if v_historic is not null then select * into po from public.payouts where id = v_historic for update; end if;
  end if;
  if po.id is null and coalesce(p_external_reference, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into po from public.payouts where id = p_external_reference::uuid and status = 'processing' and external_id is null for update;
    if po.id is not null then update public.payouts set external_id = p_external_id where id = po.id; po.external_id := p_external_id; end if;
  end if;
  if po.id is null then return jsonb_build_object('result', 'unknown'); end if;

  if p_status = 'DONE' then
    if po.status = 'completed' and po.external_id is distinct from p_external_id then
      perform app.finance_alert('Repasse em dobro detectado', 'Uma segunda transferência foi concluída para o mesmo repasse. Recupere o valor com o prestador.',
        '/hub/financeiro/repasses', 'double-done:' || p_external_id);
      return jsonb_build_object('result', 'duplicate_transfer');
    end if;
    if po.status = 'completed' then return jsonb_build_object('result', 'already'); end if;
    if po.status = 'cancelled' then
      perform app.finance_alert('Transferência concluída de repasse cancelado', 'Confira o pedido: o repasse havia sido cancelado.',
        '/hub/financeiro/repasses', 'done-cancelled:' || p_external_id);
      return jsonb_build_object('result', 'cancelled_payout');
    end if;
    update public.payouts set external_id = p_external_id, external_status = p_status where id = po.id;
    perform app.payout_done(po.id, p_fee_cents);
    return jsonb_build_object('result', 'completed', 'payout_id', po.id);
  elsif p_status in ('FAILED', 'CANCELLED') then
    if po.status = 'processing' and po.external_id = p_external_id then
      perform app.payout_failed(po.id, coalesce(nullif(p_fail_reason, ''), 'Transferência ' || p_status), true);
      return jsonb_build_object('result', 'failed', 'payout_id', po.id);
    end if;
    return jsonb_build_object('result', 'ignored');
  end if;
  update public.payouts set external_status = p_status, updated_at = now() where id = po.id and external_id = p_external_id;
  if p_status = 'BLOCKED' then
    perform app.finance_alert('Transferência bloqueada', 'O provedor bloqueou a transferência de um repasse.', '/hub/financeiro/repasses', 'blocked:' || p_external_id);
  end if;
  return jsonb_build_object('result', 'updated');
end $$;

create function public.payouts_to_reconcile(p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_service_role();
  return coalesce((select jsonb_agg(jsonb_build_object('payout_id', p.id, 'claim_token', p.claim_token, 'external_id', p.external_id,
      'uncertain', p.uncertain, 'claimed_at', p.claimed_at))
    from (select * from public.payouts where status = 'processing' and coalesce(updated_at, claimed_at) < now() - interval '10 minutes'
      order by claimed_at limit greatest(1, least(p_limit, 200))) p), '[]'::jsonb);
end $$;

-- Mecanismo de validação de saque: o provedor pergunta, antes de executar cada
-- transferência, se ela deve ser feita. Só aprova repasse conhecido, em
-- processamento, com o mesmo valor e a mesma chave, ou saque autorizado.
create function public.payout_validate_transfer(p_transfer_id text, p_value_cents bigint, p_external_reference text, p_pix_key text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  po public.payouts;
  w public.withdrawal_authorizations;
  v_result jsonb;
  norm_a text;
  norm_b text;
begin
  perform app.require_service_role();
  select * into po from public.payouts where external_id = p_transfer_id for update;
  if po.id is null and coalesce(p_external_reference, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into po from public.payouts where id = p_external_reference::uuid for update;
    if po.id is not null and po.external_id is not null and po.external_id <> p_transfer_id then
      v_result := jsonb_build_object('approved', false, 'reason', 'Já existe outra transferência para este repasse.');
      perform app.audit('transfer_refused', 'payouts', po.id::text, jsonb_build_object('transfer_id', p_transfer_id), v_result ->> 'reason');
      return v_result;
    end if;
  end if;
  if po.id is not null then
    norm_a := regexp_replace(lower(coalesce(po.pix_key, '')), '[^a-z0-9@._-]', '', 'g');
    norm_b := regexp_replace(lower(coalesce(p_pix_key, '')), '[^a-z0-9@._-]', '', 'g');
    if po.pix_key_type = 'PHONE' then norm_a := right(norm_a, 11); norm_b := right(norm_b, 11); end if;
    v_result := case
      when po.status <> 'processing' then jsonb_build_object('approved', false, 'reason', 'Repasse não está em processamento.')
      when po.amount_cents <> p_value_cents then jsonb_build_object('approved', false, 'reason', 'Valor diferente do repasse.')
      when p_pix_key is not null and norm_a <> norm_b then jsonb_build_object('approved', false, 'reason', 'Chave Pix diferente da conta conferida.')
      else jsonb_build_object('approved', true) end;
    if (v_result ->> 'approved')::boolean and po.external_id is null then
      update public.payouts set external_id = p_transfer_id, updated_at = now() where id = po.id;
    end if;
    perform app.audit(case when (v_result ->> 'approved')::boolean then 'transfer_approved' else 'transfer_refused' end,
      'payouts', po.id::text, jsonb_build_object('transfer_id', p_transfer_id, 'value_cents', p_value_cents), v_result ->> 'reason');
    return v_result;
  end if;
  select * into w from public.withdrawal_authorizations
  where used_at is null and expires_at > now() and amount_cents = p_value_cents order by created_at limit 1 for update skip locked;
  if w.id is not null then
    update public.withdrawal_authorizations set used_at = now(), transfer_id = p_transfer_id where id = w.id;
    perform app.audit('transfer_approved', 'withdrawal_authorizations', w.id::text, jsonb_build_object('transfer_id', p_transfer_id, 'value_cents', p_value_cents));
    return jsonb_build_object('approved', true);
  end if;
  perform app.audit('transfer_refused', 'transfers', p_transfer_id, jsonb_build_object('value_cents', p_value_cents), 'Transferência não reconhecida');
  perform app.finance_alert('Transferência recusada', 'Uma transferência não reconhecida foi bloqueada pelo mecanismo de validação.',
    '/hub/financeiro/conciliacao', 'refused:' || p_transfer_id);
  return jsonb_build_object('approved', false, 'reason', 'Transferência não reconhecida pela plataforma.');
end $$;

-- -----------------------------------------------------------------------------
-- E-mails
-- -----------------------------------------------------------------------------
create function public.email_claim(p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_result jsonb;
begin
  perform app.require_service_role();
  with picked as (
    select id from public.notification_logs
    where (status = 'queued' and next_attempt_at <= now()) or (status = 'sending' and updated_at < now() - interval '10 minutes')
    order by id limit greatest(1, least(p_limit, 100)) for update skip locked
  ), claimed as (
    update public.notification_logs n set status = 'sending', attempts = n.attempts + 1, updated_at = now()
    from picked where n.id = picked.id returning n.*
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'template', template, 'to_email', to_email, 'data', data,
      'idempotency_key', idempotency_key, 'attempts', attempts)), '[]'::jsonb) into v_result from claimed;
  return v_result;
end $$;

-- p_outcome: 'sent' | 'retry' (erro temporário) | 'failed' (definitivo) | 'skipped' (envio desligado)
create function public.email_result(p_id bigint, p_outcome text, p_message_id text default null, p_error text default null) returns void
language plpgsql security definer set search_path = ''
as $$
declare n public.notification_logs;
begin
  perform app.require_service_role();
  select * into n from public.notification_logs where id = p_id for update;
  if n.id is null then return; end if;
  if p_outcome = 'sent' then
    update public.notification_logs set status = 'sent', sent_at = now(), provider_message_id = p_message_id, last_error = null, updated_at = now() where id = n.id;
  elsif p_outcome = 'retry' and n.attempts < 6 then
    update public.notification_logs set status = 'queued', last_error = left(p_error, 500), updated_at = now(),
      next_attempt_at = now() + (array[interval '1 minute', interval '5 minutes', interval '30 minutes', interval '2 hours', interval '6 hours'])[least(n.attempts, 5)]
    where id = n.id;
  elsif p_outcome = 'skipped' then
    update public.notification_logs set status = 'skipped', last_error = left(p_error, 500), updated_at = now() where id = n.id;
  else
    update public.notification_logs set status = 'failed', last_error = left(p_error, 500), updated_at = now() where id = n.id;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- Rotina periódica: prazos, confirmação automática e retenção de dados (LGPD)
-- -----------------------------------------------------------------------------
create function public.finance_tick() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r record;
  v_expired integer := 0;
  v_confirmed integer := 0;
begin
  perform app.require_service_role();
  -- Pedidos sem pagamento no prazo (exceto Pix manual já informado pelo cliente).
  for r in select q.id from public.requests q
    where q.status = 'awaiting_payment' and q.payment_due_at < now()
      and not exists (select 1 from public.payments p where p.request_id = q.id and p.provider_status = 'claimed' and p.status = 'pending')
    for update skip locked
  loop
    update public.payments set status = 'cancelled', cancelled_at = now(), remote_cancel_pending = external_id is not null, updated_at = now()
    where request_id = r.id and status in ('creating', 'pending');
    update public.requests set status = 'cancelled', cancelled_at = now(), cancel_reason = 'Pagamento não confirmado no prazo.' where id = r.id;
    perform app.fin_set(r.id, 'cancelled', 'Prazo de pagamento encerrado');
    perform app.log(r.id, 'payment_expired', null);
    v_expired := v_expired + 1;
  end loop;
  -- Conclusão sem resposta do cliente no prazo: confirmação automática.
  for r in select q.id from public.requests q
    where q.status = 'completed' and q.financial_status = 'service_completed' and q.completion_deadline < now()
      and not exists (select 1 from public.disputes d where d.request_id = q.id and d.status = 'open')
    for update skip locked
  loop
    perform app.confirm_completion(r.id, 'auto');
    v_confirmed := v_confirmed + 1;
  end loop;
  -- Minimização: QR Code só enquanto a cobrança está aberta; e-mail e conteúdo de
  -- webhooks antigos são apagados (os registros financeiros permanecem).
  update public.payments set pix_qr_image = null, pix_payload = null
  where status <> 'pending' and pix_qr_image is not null and updated_at < now() - interval '1 day';
  update public.notification_logs set to_email = null, data = '{}'::jsonb
  where created_at < now() - interval '180 days' and to_email is not null;
  update public.webhook_events set payload = jsonb_build_object('redacted', true)
  where received_at < now() - interval '180 days' and not (payload ? 'redacted');
  delete from public.rate_limits where window_start < now() - interval '2 days';
  return jsonb_build_object('expired', v_expired, 'auto_confirmed', v_confirmed);
end $$;

-- =============================================================================
-- Equipe financeira
-- =============================================================================
create function app.ledger_balance(p_account text, p_from timestamptz default null, p_to timestamptz default null) returns bigint
language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(case when direction = 'D' then amount_cents else -amount_cents end), 0)
  from public.financial_ledger where account = p_account
    and (p_from is null or created_at >= p_from) and (p_to is null or created_at < p_to)
$$;

create function public.finance_dashboard(p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_volume bigint;
  v_count integer;
  v_revenue bigint;
  v_fees bigint;
  v_subsidy bigint;
  v_refunded bigint;
  v_created integer;
  v_paid integer;
begin
  perform app.require_staff('finance');
  v_from := (coalesce(p_from, (now() at time zone 'America/Fortaleza')::date - 29)::timestamp) at time zone 'America/Fortaleza';
  v_to := ((coalesce(p_to, (now() at time zone 'America/Fortaleza')::date) + 1)::timestamp) at time zone 'America/Fortaleza';
  select coalesce(sum(amount_cents), 0), count(*) into v_volume, v_count from public.payments
  where orphan_reason is null and confirmed_at >= v_from and confirmed_at < v_to;
  v_revenue := -app.ledger_balance('platform_revenue', v_from, v_to);
  v_fees := app.ledger_balance('gateway_fees', v_from, v_to);
  v_subsidy := app.ledger_balance('promotion_subsidy', v_from, v_to);
  select coalesce(sum(f.amount_cents), 0) into v_refunded from public.refunds f join public.payments p on p.id = f.payment_id
  where f.status = 'done' and p.orphan_reason is null and f.done_at >= v_from and f.done_at < v_to;
  select count(*), count(*) filter (where financial_status <> 'pending_payment' and financial_status <> 'cancelled')
  into v_created, v_paid from public.requests where created_at >= v_from and created_at < v_to;

  return jsonb_build_object(
    'period', jsonb_build_object('from', v_from, 'to', v_to),
    'volume', v_volume / 100.0, 'payments_count', v_count,
    'revenue', v_revenue / 100.0, 'fees', v_fees / 100.0, 'subsidy', v_subsidy / 100.0,
    'net_revenue', (v_revenue - v_fees - v_subsidy) / 100.0, 'refunded', v_refunded / 100.0,
    'balances', jsonb_build_object(
      'cash_gateway', app.ledger_balance('cash_gateway') / 100.0,
      'customer_funds_held', -app.ledger_balance('customer_funds_held') / 100.0,
      'provider_payable', -app.ledger_balance('provider_payable') / 100.0,
      'provider_receivable', app.ledger_balance('provider_receivable') / 100.0),
    'payouts', (select jsonb_build_object(
        'scheduled_count', count(*) filter (where status = 'scheduled'),
        'scheduled', coalesce(sum(amount_cents) filter (where status = 'scheduled'), 0) / 100.0,
        'on_hold', coalesce(sum(amount_cents) filter (where status = 'on_hold'), 0) / 100.0,
        'on_hold_count', count(*) filter (where status = 'on_hold'),
        'processing', coalesce(sum(amount_cents) filter (where status = 'processing'), 0) / 100.0,
        'failed_count', count(*) filter (where status = 'failed'),
        'completed_period', coalesce(sum(amount_cents) filter (where status = 'completed' and completed_at >= v_from and completed_at < v_to), 0) / 100.0,
        'completed_period_count', count(*) filter (where status = 'completed' and completed_at >= v_from and completed_at < v_to),
        'avg_days_to_payout', round(avg(extract(epoch from completed_at - created_at) / 86400) filter (where status = 'completed'), 1))
      from public.payouts),
    'disputes_open', (select count(*) from public.disputes where status = 'open'),
    'accounts_pending', (select count(*) from public.provider_payment_accounts where status = 'pending_review'),
    'failures', jsonb_build_object(
      'payouts_final', (select count(*) from public.payouts where status = 'failed' and final_failure),
      'payouts_uncertain', (select count(*) from public.payouts where status = 'processing' and uncertain),
      'refunds_failed', (select count(*) from public.refunds f where f.status = 'failed'
        and not exists (select 1 from public.refunds g where g.payment_id = f.payment_id and g.status <> 'failed')),
      'webhooks_failed', (select count(*) from public.webhook_events where status = 'failed'),
      'emails_failed', (select count(*) from public.notification_logs where status = 'failed'),
      'payments_failed', (select count(*) from public.payments where status = 'failed' and created_at >= v_from)),
    'kpis', jsonb_build_object(
      'avg_ticket', case when v_count > 0 then round(v_volume / 100.0 / v_count, 2) end,
      'take_rate', case when v_volume > 0 then round(v_revenue * 100.0 / v_volume, 2) end,
      'conversion', case when v_created > 0 then round(v_paid * 100.0 / v_created, 1) end,
      'refund_rate', case when v_volume > 0 then round(v_refunded * 100.0 / v_volume, 2) end),
    'by_category', coalesce((select jsonb_agg(x order by x.volume desc) from (
        select coalesce(c.name, 'Sem categoria') as name, count(distinct q.id) as count,
          coalesce(sum(p.amount_cents), 0) / 100.0 as volume,
          coalesce((select -sum(case when l.direction = 'D' then l.amount_cents else -l.amount_cents end) from public.financial_ledger l
            join public.requests q2 on q2.id = l.request_id join public.services s2 on s2.id = q2.service_id
            where l.account = 'platform_revenue' and s2.category_code is not distinct from s.category_code
              and l.created_at >= v_from and l.created_at < v_to), 0) / 100.0 as revenue
        from public.payments p join public.requests q on q.id = p.request_id join public.services s on s.id = q.service_id
        left join public.service_categories c on c.code = s.category_code
        where p.orphan_reason is null and p.confirmed_at >= v_from and p.confirmed_at < v_to
        group by c.name, s.category_code) x), '[]'::jsonb),
    'by_provider', coalesce((select jsonb_agg(x order by x.earned desc) from (
        select pf.full_name as name, po.provider_id, count(*) as jobs, sum(po.amount_cents) / 100.0 as earned,
          coalesce(sum(po.amount_cents) filter (where po.status = 'completed'), 0) / 100.0 as paid,
          coalesce(sum(po.amount_cents) filter (where po.status in ('scheduled', 'on_hold', 'processing', 'failed')), 0) / 100.0 as pending
        from public.payouts po join public.profiles pf on pf.id = po.provider_id
        where po.created_at >= v_from and po.created_at < v_to
        group by pf.full_name, po.provider_id order by sum(po.amount_cents) desc limit 20) x), '[]'::jsonb),
    'daily', coalesce((select jsonb_agg(x order by x.day) from (
        select (confirmed_at at time zone 'America/Fortaleza')::date as day, sum(amount_cents) / 100.0 as volume, count(*) as count
        from public.payments where orphan_reason is null and confirmed_at >= v_from and confirmed_at < v_to
        group by 1) x), '[]'::jsonb));
end $$;

create function public.finance_payments(p_status text default null, p_limit integer default 100) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_staff('finance');
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'request_id', p.request_id, 'number', r.number,
      'customer', c.full_name, 'service', s.name, 'kind', p.kind, 'method', p.method, 'status', p.status,
      'amount', p.amount_cents / 100.0, 'fee', p.fee_cents / 100.0, 'external_id', p.external_id,
      'provider_status', p.provider_status, 'orphan_reason', p.orphan_reason, 'manual_reference', p.manual_reference,
      'created_at', p.created_at, 'confirmed_at', p.confirmed_at, 'refunded_at', p.refunded_at, 'last_error', p.last_error,
      'refund', (select jsonb_build_object('id', f.id, 'status', f.status, 'reason', f.reason, 'last_error', f.last_error)
        from public.refunds f where f.payment_id = p.id order by f.created_at desc limit 1)) order by p.created_at desc)
    from (select * from public.payments
      where p_status is null or status = p_status or (p_status = 'claimed' and provider_status = 'claimed' and status = 'pending')
      order by created_at desc limit greatest(1, least(p_limit, 500))) p
    join public.requests r on r.id = p.request_id join public.profiles c on c.id = r.customer_id
    join public.services s on s.id = r.service_id), '[]'::jsonb);
end $$;

create function public.finance_payouts(p_status text default null, p_limit integer default 100) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_staff('finance');
  return coalesce((select jsonb_agg(jsonb_build_object('id', po.id, 'request_id', po.request_id, 'number', r.number,
      'provider', pf.full_name, 'provider_id', po.provider_id, 'amount', po.amount_cents / 100.0, 'status', po.status,
      'scheduled_for', po.scheduled_for, 'attempts', po.attempts, 'next_attempt_at', po.next_attempt_at,
      'uncertain', po.uncertain, 'final_failure', po.final_failure, 'fail_reason', po.fail_reason, 'hold_reason', po.hold_reason,
      'external_id', po.external_id, 'external_status', po.external_status, 'completed_at', po.completed_at,
      'manual_reference', po.manual_reference, 'financial_status', r.financial_status) order by po.scheduled_for)
    from (select * from public.payouts where p_status is null or status = p_status
      order by scheduled_for desc limit greatest(1, least(p_limit, 500))) po
    join public.requests r on r.id = po.request_id join public.profiles pf on pf.id = po.provider_id), '[]'::jsonb);
end $$;

create function public.finance_disputes() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_staff('finance');
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'request_id', d.request_id, 'number', r.number,
      'service', s.name, 'customer', c.full_name, 'provider', pf.full_name, 'total', r.total, 'provider_net', r.provider_net,
      'reason', d.reason, 'opened_role', d.opened_role, 'status', d.status, 'created_at', d.created_at,
      'resolution_note', d.resolution_note, 'resolved_at', d.resolved_at) order by (d.status = 'open') desc, d.created_at desc)
    from (select * from public.disputes order by created_at desc limit 200) d
    join public.requests r on r.id = d.request_id join public.services s on s.id = r.service_id
    join public.profiles c on c.id = r.customer_id left join public.profiles pf on pf.id = r.provider_id), '[]'::jsonb);
end $$;

create function public.finance_accounts() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_staff('finance');
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'provider_id', a.provider_id, 'provider', pf.full_name,
      'legal_name', pr.legal_name, 'doc_number', pr.doc_number, 'pix_key_type', a.pix_key_type, 'pix_key', a.pix_key,
      'holder_name', a.holder_name, 'holder_doc', a.holder_doc, 'status', a.status, 'created_at', a.created_at,
      'reviewed_at', a.reviewed_at, 'usable_from', a.usable_from, 'review_note', a.review_note)
    order by (a.status = 'pending_review') desc, a.created_at desc)
    from (select * from public.provider_payment_accounts where status in ('pending_review', 'active') order by created_at desc limit 300) a
    join public.providers pr on pr.id = a.provider_id join public.profiles pf on pf.id = a.provider_id), '[]'::jsonb);
end $$;

-- Pendências para conciliar, com o balancete do razão.
create function public.finance_reconciliation() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_staff('finance');
  return jsonb_build_object(
    'trial_balance', (select coalesce(sum(case when direction = 'D' then amount_cents else -amount_cents end), 0) from public.financial_ledger),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('account', account, 'debits', d / 100.0, 'credits', c / 100.0,
        'balance', (d - c) / 100.0) order by account)
      from (select account, sum(amount_cents) filter (where direction = 'D') as d, coalesce(sum(amount_cents) filter (where direction = 'C'), 0) as c
            from public.financial_ledger group by account) x), '[]'::jsonb),
    'issues', coalesce((select jsonb_agg(i order by i.at desc) from (
        select 'payment_stale' as kind, p.id::text as ref, r.number, 'Cobrança sem confirmação há mais de 1 hora' as detail, p.created_at as at
          from public.payments p join public.requests r on r.id = p.request_id
          where p.status = 'pending' and p.created_at < now() - interval '1 hour'
        union all
        select 'payment_failed', p.id::text, r.number, 'Cobrança não criada: ' || coalesce(p.last_error, ''), p.created_at
          from public.payments p join public.requests r on r.id = p.request_id
          where p.status = 'failed' and p.created_at > now() - interval '7 days' and r.status = 'awaiting_payment'
        union all
        select 'remote_cancel', p.id::text, r.number, 'Cobrança ainda não removida no provedor', p.updated_at
          from public.payments p join public.requests r on r.id = p.request_id where p.remote_cancel_pending
        union all
        select 'payout_uncertain', po.id::text, r.number, 'Transferência sem confirmação do provedor', po.claimed_at
          from public.payouts po join public.requests r on r.id = po.request_id where po.status = 'processing' and po.uncertain
        union all
        select 'payout_stuck', po.id::text, r.number, 'Transferência em processamento há mais de 1 hora', po.claimed_at
          from public.payouts po join public.requests r on r.id = po.request_id
          where po.status = 'processing' and not po.uncertain and po.claimed_at < now() - interval '1 hour'
        union all
        select 'payout_failed', po.id::text, r.number, 'Repasse com falha definitiva: ' || coalesce(po.fail_reason, ''), po.updated_at
          from public.payouts po join public.requests r on r.id = po.request_id where po.status = 'failed' and po.final_failure
        union all
        select 'refund_failed', f.id::text, r.number, 'Estorno não concluído: ' || coalesce(f.last_error, ''), f.created_at
          from public.refunds f join public.payments p on p.id = f.payment_id join public.requests r on r.id = p.request_id
          where f.status = 'failed' and not exists (select 1 from public.refunds g where g.payment_id = f.payment_id and g.status <> 'failed')
        union all
        select 'refund_manual', f.id::text, r.number, 'Estorno de Pix manual a fazer pela equipe', f.created_at
          from public.refunds f join public.payments p on p.id = f.payment_id join public.requests r on r.id = p.request_id
          where f.status = 'requested' and p.method = 'pix_manual'
        union all
        select 'webhook_failed', w.id::text, null, 'Webhook com erro: ' || w.event_type || ' — ' || coalesce(w.last_error, ''), w.received_at
          from public.webhook_events w where w.status = 'failed'
        union all
        select 'confirmed_unpaid_payout', r.id::text, r.number, 'Conclusão reconhecida sem repasse', r.completion_confirmed_at
          from public.requests r where r.recognized_journal is not null and not exists (select 1 from public.payouts po where po.request_id = r.id)
      ) i), '[]'::jsonb));
end $$;

create function public.finance_audit(p_entity text default null, p_limit integer default 100) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_any_staff();
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'at', a.at, 'actor', pf.full_name, 'actor_role', a.actor_role,
      'action', a.action, 'entity', a.entity, 'entity_id', a.entity_id, 'before', a.before, 'after', a.after, 'note', a.note) order by a.id desc)
    from (select * from public.audit_logs where p_entity is null or entity = p_entity order by id desc limit greatest(1, least(p_limit, 500))) a
    left join public.profiles pf on pf.id = a.actor_id), '[]'::jsonb);
end $$;

-- Pix manual: confirmação com o identificador da transação (E2E ou comprovante).
create function public.finance_confirm_manual_payment(p_payment_id uuid, p_reference text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_staff('finance');
  p public.payments;
begin
  if length(btrim(coalesce(p_reference, ''))) < 6 then
    perform app.fail('reference_required', 'Informe o identificador da transação Pix (E2E) ou do comprovante.');
  end if;
  select * into p from public.payments where id = p_payment_id for update;
  if p.id is null or p.method <> 'pix_manual' or p.status not in ('pending', 'expired', 'cancelled') then
    perform app.fail('cannot_confirm', 'Este pagamento não está aguardando confirmação manual.');
  end if;
  if exists (select 1 from public.payments where manual_reference = btrim(p_reference)) then
    perform app.fail('reference_used', 'Este identificador já foi usado em outro pagamento.');
  end if;
  update public.payments set manual_reference = btrim(p_reference), confirmed_by = v_uid where id = p.id;
  perform app.audit('manual_payment_confirmed', 'payments', p.id::text, jsonb_build_object('reference', btrim(p_reference)));
  perform app.apply_confirmed(p.id, p.amount_cents, p.amount_cents);
end $$;

create function public.finance_mark_refund_done(p_refund_id uuid, p_reference text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  f public.refunds;
  p public.payments;
begin
  perform app.require_staff('finance');
  if length(btrim(coalesce(p_reference, ''))) < 6 then perform app.fail('reference_required', 'Informe o identificador da devolução Pix.'); end if;
  select * into f from public.refunds where id = p_refund_id for update;
  select * into p from public.payments where id = f.payment_id;
  if f.id is null or p.method <> 'pix_manual' or f.status not in ('requested', 'processing') then
    perform app.fail('cannot_mark', 'Este estorno não está aguardando registro manual.');
  end if;
  update public.refunds set note = coalesce(note, '') || ' · ref. ' || btrim(p_reference), external_status = 'manual' where id = f.id;
  perform app.audit('manual_refund_done', 'refunds', f.id::text, jsonb_build_object('reference', btrim(p_reference)));
  perform app.apply_refunded(p.id);
end $$;

create function public.finance_request_refund(p_request_id uuid, p_note text) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_staff('finance');
begin
  perform app.hit('finance_refund:' || v_uid, 30, 3600);
  if length(btrim(coalesce(p_note, ''))) < 10 then perform app.fail('note_required', 'Registre o motivo do estorno (ao menos 10 caracteres).'); end if;
  if (select financial_status from public.requests where id = p_request_id) not in
      ('payment_confirmed', 'service_in_progress', 'service_completed', 'payout_scheduled', 'payout_processing', 'payout_failed', 'payout_completed', 'disputed') then
    perform app.fail('not_refundable', 'Este pedido não tem pagamento a estornar.');
  end if;
  perform app.reverse_and_refund(p_request_id, btrim(p_note), false, 'finance');
end $$;

create function public.finance_retry_refund(p_refund_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare f public.refunds;
begin
  perform app.require_staff('finance');
  select * into f from public.refunds where id = p_refund_id and status = 'failed';
  if f.id is null then perform app.fail('cannot_retry', 'Este estorno não está com falha.'); end if;
  insert into public.refunds (payment_id, amount_cents, reason, note, requested_by)
  values (f.payment_id, f.amount_cents, f.reason, 'Nova tentativa', auth.uid());
end $$;

create function public.finance_resolve_dispute(p_dispute_id uuid, p_outcome text, p_note text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_staff('finance');
  d public.disputes;
  r public.requests;
begin
  if p_outcome not in ('provider', 'customer') then perform app.fail('invalid_outcome', 'Escolha a decisão.'); end if;
  if length(btrim(coalesce(p_note, ''))) < 10 then perform app.fail('note_required', 'Registre a fundamentação da decisão.'); end if;
  select * into d from public.disputes where id = p_dispute_id and status = 'open' for update;
  if d.id is null then perform app.fail('already_resolved', 'Esta disputa já foi decidida.'); end if;
  select * into r from public.requests where id = d.request_id for update;
  update public.disputes set status = case when p_outcome = 'provider' then 'resolved_provider' else 'resolved_customer' end,
    resolution_note = btrim(p_note), resolved_by = v_uid, resolved_at = now() where id = d.id;
  if p_outcome = 'provider' then
    if r.recognized_journal is null then
      perform app.confirm_completion(r.id, 'finance', true);
    else
      update public.payouts set status = 'scheduled', hold_reason = null, updated_at = now() where request_id = r.id and status = 'on_hold';
      perform app.fin_set(r.id, 'payout_scheduled', 'Disputa decidida a favor do prestador');
    end if;
  else
    perform app.reverse_and_refund(r.id, 'Disputa decidida a favor do cliente: ' || left(btrim(p_note), 200), false, 'dispute');
  end if;
  perform app.log(r.id, 'dispute_resolved', 'hub_admin', btrim(p_note));
end $$;

create function public.finance_hold_payout(p_payout_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_staff('finance');
  if length(btrim(coalesce(p_reason, ''))) < 10 then perform app.fail('reason_required', 'Registre o motivo da retenção.'); end if;
  update public.payouts set status = 'on_hold', hold_reason = 'finance: ' || left(btrim(p_reason), 200), updated_at = now()
  where id = p_payout_id and status in ('scheduled', 'failed');
  if not found then perform app.fail('cannot_hold', 'Só é possível reter um repasse agendado ou com falha.'); end if;
end $$;

create function public.finance_release_payout(p_payout_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare po public.payouts;
begin
  perform app.require_staff('finance');
  select * into po from public.payouts where id = p_payout_id for update;
  if po.id is null or po.status <> 'on_hold' or po.hold_reason = 'dispute' then
    perform app.fail('cannot_release', 'Este repasse não está retido pela equipe (disputas se decidem na tela de disputas).');
  end if;
  update public.payouts set status = 'scheduled', hold_reason = null, final_failure = false, updated_at = now() where id = po.id;
  if (select financial_status from public.requests where id = po.request_id) = 'payout_failed' then
    perform app.fin_set(po.request_id, 'payout_scheduled', 'Repasse liberado pela equipe');
  end if;
end $$;

create function public.finance_retry_payout(p_payout_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare po public.payouts;
begin
  perform app.require_staff('finance');
  select * into po from public.payouts where id = p_payout_id for update;
  if po.id is null or po.status <> 'failed' then perform app.fail('cannot_retry', 'Só é possível tentar de novo um repasse com falha.'); end if;
  update public.payouts set status = 'scheduled', attempts = 0, final_failure = false, next_attempt_at = null, scheduled_for = now(), updated_at = now()
  where id = po.id;
  perform app.fin_set(po.request_id, 'payout_scheduled', 'Nova tentativa solicitada pela equipe');
end $$;

-- Repasse sem resposta do provedor: a equipe confere no painel do provedor e
-- registra se a transferência saiu ou não.
create function public.finance_resolve_uncertain_payout(p_payout_id uuid, p_sent boolean, p_transfer_id text, p_note text) returns void
language plpgsql security definer set search_path = ''
as $$
declare po public.payouts;
begin
  perform app.require_staff('finance');
  if length(btrim(coalesce(p_note, ''))) < 10 then perform app.fail('note_required', 'Registre o que foi conferido no provedor.'); end if;
  select * into po from public.payouts where id = p_payout_id for update;
  if po.id is null or po.status <> 'processing' or not po.uncertain then
    perform app.fail('not_uncertain', 'Este repasse não está aguardando conciliação manual.');
  end if;
  perform set_config('app.audit_note', btrim(p_note), true);
  if p_sent then
    if length(btrim(coalesce(p_transfer_id, ''))) < 3 then perform app.fail('transfer_required', 'Informe o identificador da transferência.'); end if;
    update public.payouts set external_id = btrim(p_transfer_id), manual_reference = btrim(p_note) where id = po.id;
    perform app.payout_done(po.id, null);
  else
    perform app.payout_failed(po.id, 'Conferido pela equipe: transferência não realizada', true);
  end if;
  perform set_config('app.audit_note', '', true);
end $$;

-- Repasse manual (payout_mode = 'manual'): a equipe paga e registra o comprovante.
create function public.finance_mark_payout_paid(p_payout_id uuid, p_reference text) returns void
language plpgsql security definer set search_path = ''
as $$
declare po public.payouts;
begin
  perform app.require_staff('finance');
  if length(btrim(coalesce(p_reference, ''))) < 6 then perform app.fail('reference_required', 'Informe o identificador do Pix enviado ao prestador.'); end if;
  select * into po from public.payouts where id = p_payout_id for update;
  if po.id is null or po.status not in ('scheduled', 'failed') or (po.status = 'on_hold') then
    perform app.fail('cannot_mark', 'Este repasse não está disponível para pagamento.');
  end if;
  if exists (select 1 from public.disputes where request_id = po.request_id and status = 'open') then
    perform app.fail('disputed', 'Há uma disputa aberta neste pedido.');
  end if;
  if po.scheduled_for > now() then perform app.fail('not_due', 'O repasse ainda não venceu.'); end if;
  update public.payouts set manual_reference = btrim(p_reference) where id = po.id;
  perform app.payout_done(po.id, null);
end $$;

create function public.finance_review_account(p_account_id uuid, p_approve boolean, p_note text default '') returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_staff('finance');
  a public.provider_payment_accounts;
begin
  select * into a from public.provider_payment_accounts where id = p_account_id and status = 'pending_review' for update;
  if a.id is null then perform app.fail('not_pending', 'Esta conta não está aguardando conferência.'); end if;
  if not p_approve and length(btrim(coalesce(p_note, ''))) < 10 then
    perform app.fail('note_required', 'Ao recusar, informe o motivo ao prestador.');
  end if;
  if p_approve then
    update public.provider_payment_accounts set status = 'replaced' where provider_id = a.provider_id and status = 'active';
    update public.provider_payment_accounts set status = 'active', reviewed_by = v_uid, reviewed_at = now(),
      review_note = nullif(btrim(coalesce(p_note, '')), ''),
      usable_from = now() + make_interval(hours => (select account_cooldown_hours from public.settings))
    where id = a.id;
    update public.payouts set status = 'scheduled', hold_reason = null, updated_at = now()
    where provider_id = a.provider_id and status = 'on_hold' and hold_reason = 'no_account';
    perform app.notify(a.provider_id, 'Conta de recebimento aprovada', 'Sua chave Pix foi conferida e passa a receber os repasses.', '/prestador/ganhos');
  else
    update public.provider_payment_accounts set status = 'rejected', reviewed_by = v_uid, reviewed_at = now(), review_note = btrim(p_note) where id = a.id;
    perform app.notify(a.provider_id, 'Conta de recebimento recusada', 'Veja o motivo e cadastre a chave de novo.', '/prestador/ganhos');
  end if;
end $$;

create function public.finance_authorize_withdrawal(p_amount numeric, p_note text) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_staff('finance');
  v_id uuid;
begin
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then perform app.fail('invalid_amount', 'Informe um valor válido.'); end if;
  if length(btrim(coalesce(p_note, ''))) < 5 then perform app.fail('note_required', 'Informe a finalidade do saque.'); end if;
  insert into public.withdrawal_authorizations (amount_cents, note, created_by, expires_at)
  values (app.cents(p_amount), btrim(p_note), v_uid, now() + interval '30 minutes') returning id into v_id;
  return v_id;
end $$;

-- =============================================================================
-- Administração comercial (papel interno 'admin')
-- =============================================================================
create or replace function public.admin_overview() returns jsonb
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
        'awaiting_payment', count(*) filter (where status = 'awaiting_payment'),
        'searching', count(*) filter (where status = 'searching'),
        'active', count(*) filter (where status in ('accepted', 'en_route', 'in_progress')),
        'completed', count(*) filter (where status = 'completed'),
        'cancelled', count(*) filter (where status = 'cancelled'))
      from public.requests),
    'rating', (select jsonb_build_object('average', round(avg(rating)::numeric, 1), 'count', count(*)) from public.reviews),
    'payments_to_confirm', (select count(*) from public.payments where method = 'pix_manual' and status = 'pending' and provider_status = 'claimed'),
    'settings', (select jsonb_build_object('commission_percent', s.commission_percent, 'payout_days', s.payout_days,
        'search_radius_km', s.search_radius_km, 'pix_key', s.pix_key, 'pix_holder', s.pix_holder,
        'setup_code_pending', s.setup_code_hash is not null, 'setup_code_role', s.setup_code_role,
        'payment_provider', s.payment_provider, 'payout_mode', s.payout_mode,
        'payment_window_minutes', s.payment_window_minutes, 'confirm_hours', s.confirm_hours,
        'platform_fee', s.platform_fee, 'min_charge_amount', s.min_charge_amount,
        'account_cooldown_hours', s.account_cooldown_hours, 'payout_max_attempts', s.payout_max_attempts,
        'default_region_id', s.default_region_id) from public.settings s),
    'contract', (select jsonb_build_object('version', version, 'title', title) from public.contract_versions where is_current));
end $$;

-- Regras financeiras. Valem para pedidos novos; os existentes mantêm o que foi
-- registrado na contratação.
create function public.admin_save_finance_settings(p_commission_percent numeric, p_payout_days integer, p_confirm_hours integer,
  p_payment_window_minutes integer, p_platform_fee numeric, p_min_charge_amount numeric, p_payment_provider text, p_payout_mode text,
  p_account_cooldown_hours integer) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  if p_commission_percent is null or p_commission_percent not between 0 and 60 then perform app.fail('invalid_commission', 'A comissão deve ficar entre 0% e 60%.'); end if;
  if p_payout_days is null or p_payout_days not between 0 and 60 then perform app.fail('invalid_payout', 'O prazo de repasse deve ficar entre 0 e 60 dias.'); end if;
  if p_confirm_hours is null or p_confirm_hours not between 1 and 168 then perform app.fail('invalid_confirm', 'O prazo de confirmação deve ficar entre 1 e 168 horas.'); end if;
  if p_payment_window_minutes is null or p_payment_window_minutes not between 10 and 1440 then perform app.fail('invalid_window', 'O prazo para pagar deve ficar entre 10 e 1440 minutos.'); end if;
  if p_platform_fee is null or p_platform_fee not between 0 and 100 then perform app.fail('invalid_fee', 'A taxa deve ficar entre R$ 0 e R$ 100.'); end if;
  if p_min_charge_amount is null or p_min_charge_amount not between 1 and 100 then perform app.fail('invalid_min', 'O mínimo deve ficar entre R$ 1 e R$ 100.'); end if;
  if p_payment_provider not in ('asaas', 'manual') or p_payout_mode not in ('asaas', 'manual') then perform app.fail('invalid_mode', 'Modo inválido.'); end if;
  if p_account_cooldown_hours is null or p_account_cooldown_hours not between 0 and 168 then perform app.fail('invalid_cooldown', 'A carência deve ficar entre 0 e 168 horas.'); end if;
  if p_payment_provider = 'manual' and (select pix_key from public.settings) is null then
    perform app.fail('pix_required', 'Cadastre a chave Pix da HUB antes de usar o modo manual.');
  end if;
  update public.settings set commission_percent = p_commission_percent, payout_days = p_payout_days, confirm_hours = p_confirm_hours,
    payment_window_minutes = p_payment_window_minutes, platform_fee = round(p_platform_fee, 2), min_charge_amount = round(p_min_charge_amount, 2),
    payment_provider = p_payment_provider, payout_mode = p_payout_mode, account_cooldown_hours = p_account_cooldown_hours, updated_at = now();
end $$;

create or replace function public.admin_save_pix(p_pix_key text, p_pix_holder text) returns void
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
  if v_key is null and (select payment_provider from public.settings) = 'manual' then
    perform app.fail('pix_in_use', 'O modo de pagamento manual usa esta chave. Mude o modo antes de removê-la.');
  end if;
  update public.settings set pix_key = v_key, pix_holder = case when v_key is null then null else v_holder end, updated_at = now();
end $$;

create function public.admin_catalog() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  return jsonb_build_object(
    'categories', coalesce((select jsonb_agg(to_jsonb(c) order by c.sort, c.name) from public.service_categories c), '[]'::jsonb),
    'regions', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('is_default', r.id = s.default_region_id) order by r.name)
      from public.regions r cross join public.settings s), '[]'::jsonb),
    'services', coalesce((select jsonb_agg(to_jsonb(sv) || jsonb_build_object('prices', coalesce((select jsonb_agg(jsonb_build_object(
        'region_id', sp.region_id, 'price', sp.price, 'active', sp.active)) from public.service_prices sp where sp.service_id = sv.id), '[]'::jsonb))
      order by sv.sort, sv.name) from public.services sv), '[]'::jsonb),
    'promotions', coalesce((select jsonb_agg(to_jsonb(p) || jsonb_build_object('running', p.active and now() >= p.starts_at and now() < p.ends_at)
      order by p.ends_at desc) from public.promotions p), '[]'::jsonb),
    'commission_rules', coalesce((select jsonb_agg(to_jsonb(cr) || jsonb_build_object('provider_name', pf.full_name,
        'running', cr.active and (cr.starts_at is null or cr.starts_at <= now()) and (cr.ends_at is null or cr.ends_at > now()))
      order by cr.active desc, cr.created_at desc)
      from public.commission_rules cr left join public.profiles pf on pf.id = cr.provider_id), '[]'::jsonb),
    'providers', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', pf.full_name) order by pf.full_name)
      from public.providers p join public.profiles pf on pf.id = p.id where p.status in ('approved', 'suspended')), '[]'::jsonb));
end $$;

create function public.admin_save_category(p_code text, p_name text, p_sort integer, p_active boolean) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  if coalesce(p_code, '') !~ '^[a-z_]{3,30}$' then perform app.fail('invalid_code', 'Código: letras minúsculas e _ (3 a 30).'); end if;
  if length(btrim(coalesce(p_name, ''))) < 3 then perform app.fail('invalid_name', 'Informe o nome da categoria.'); end if;
  insert into public.service_categories (code, name, sort, active) values (p_code, btrim(p_name), coalesce(p_sort, 0), coalesce(p_active, true))
  on conflict (code) do update set name = excluded.name, sort = excluded.sort, active = excluded.active;
end $$;

create function public.admin_save_service(p_id uuid, p_name text, p_description text, p_base_price numeric, p_est_minutes integer,
  p_active boolean, p_category_code text) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  if length(btrim(coalesce(p_name, ''))) < 3 then perform app.fail('invalid_name', 'Informe o nome do serviço.'); end if;
  if p_base_price is null or p_base_price <= 0 or p_base_price > 50000 then perform app.fail('invalid_price', 'Informe um preço válido.'); end if;
  if p_est_minutes is null or p_est_minutes not between 5 and 600 then perform app.fail('invalid_minutes', 'Informe a duração entre 5 e 600 minutos.'); end if;
  if not exists (select 1 from public.service_categories where code = p_category_code) then perform app.fail('invalid_category', 'Escolha a categoria.'); end if;
  if p_id is null then
    insert into public.services (code, name, description, base_price, est_minutes, active, sort, category_code)
    values ('servico_' || translate(left(gen_random_uuid()::text, 8), '0123456789-', 'abcdefghij_'), btrim(p_name),
      btrim(coalesce(p_description, '')), round(p_base_price, 2), p_est_minutes, coalesce(p_active, true),
      (select coalesce(max(sort), 0) + 10 from public.services), p_category_code);
  else
    update public.services set name = btrim(p_name), description = btrim(coalesce(p_description, '')),
      base_price = round(p_base_price, 2), est_minutes = p_est_minutes, active = coalesce(p_active, true), category_code = p_category_code
    where id = p_id;
    if not found then perform app.fail('not_found', 'Serviço não encontrado.'); end if;
  end if;
end $$;

create function public.admin_save_region(p_id uuid, p_code text, p_name text, p_uf text, p_lat double precision, p_lng double precision,
  p_radius_km integer, p_active boolean, p_default boolean) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  perform app.require_role('hub_admin');
  if coalesce(p_code, '') !~ '^[a-z_]{3,40}$' then perform app.fail('invalid_code', 'Código: letras minúsculas e _ (3 a 40).'); end if;
  if length(btrim(coalesce(p_name, ''))) < 3 then perform app.fail('invalid_name', 'Informe o nome da região.'); end if;
  if upper(coalesce(p_uf, '')) !~ '^[A-Z]{2}$' then perform app.fail('invalid_uf', 'Informe a UF.'); end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then perform app.fail('invalid_center', 'Informe o centro da região.'); end if;
  if p_radius_km is null or p_radius_km not between 1 and 300 then perform app.fail('invalid_radius', 'O raio deve ficar entre 1 e 300 km.'); end if;
  if p_id is null then
    insert into public.regions (code, name, uf, center_lat, center_lng, radius_km, active)
    values (p_code, btrim(p_name), upper(p_uf), p_lat, p_lng, p_radius_km, coalesce(p_active, true)) returning id into v_id;
  else
    update public.regions set code = p_code, name = btrim(p_name), uf = upper(p_uf), center_lat = p_lat, center_lng = p_lng,
      radius_km = p_radius_km, active = coalesce(p_active, true) where id = p_id returning id into v_id;
    if v_id is null then perform app.fail('not_found', 'Região não encontrada.'); end if;
  end if;
  if coalesce(p_default, false) then update public.settings set default_region_id = v_id; end if;
  return v_id;
end $$;

-- Preço por região. Preço nulo remove o preço específico (volta ao de tabela).
create function public.admin_set_region_price(p_service_id uuid, p_region_id uuid, p_price numeric) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  if p_price is null then
    delete from public.service_prices where service_id = p_service_id and region_id = p_region_id;
    return;
  end if;
  if p_price <= 0 or p_price > 50000 then perform app.fail('invalid_price', 'Informe um preço válido.'); end if;
  insert into public.service_prices (service_id, region_id, price) values (p_service_id, p_region_id, round(p_price, 2))
  on conflict (service_id, region_id) do update set price = excluded.price, active = true, updated_at = now();
end $$;

create function public.admin_save_promotion(p_id uuid, p_name text, p_kind text, p_value numeric, p_service_id uuid,
  p_category_code text, p_region_id uuid, p_starts_at timestamptz, p_ends_at timestamptz, p_max_redemptions integer, p_active boolean) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('hub_admin');
  v_id uuid;
begin
  if length(btrim(coalesce(p_name, ''))) < 3 then perform app.fail('invalid_name', 'Informe o nome da promoção.'); end if;
  if p_kind not in ('percent', 'fixed') then perform app.fail('invalid_kind', 'Escolha o tipo de desconto.'); end if;
  if p_value is null or p_value <= 0 or (p_kind = 'percent' and p_value >= 100) or p_value > 50000 then perform app.fail('invalid_value', 'Informe um desconto válido.'); end if;
  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then perform app.fail('invalid_period', 'Informe o período (fim depois do início).'); end if;
  if p_id is null then
    insert into public.promotions (name, kind, value, service_id, category_code, region_id, starts_at, ends_at, max_redemptions, active, created_by)
    values (btrim(p_name), p_kind, round(p_value, 2), p_service_id, nullif(p_category_code, ''), p_region_id, p_starts_at, p_ends_at,
      p_max_redemptions, coalesce(p_active, true), v_uid) returning id into v_id;
  else
    update public.promotions set name = btrim(p_name), kind = p_kind, value = round(p_value, 2), service_id = p_service_id,
      category_code = nullif(p_category_code, ''), region_id = p_region_id, starts_at = p_starts_at, ends_at = p_ends_at,
      max_redemptions = p_max_redemptions, active = coalesce(p_active, true)
    where id = p_id returning id into v_id;
    if v_id is null then perform app.fail('not_found', 'Promoção não encontrada.'); end if;
  end if;
  return v_id;
end $$;

create function public.admin_create_commission_rule(p_name text, p_scope text, p_category_code text, p_provider_id uuid,
  p_percent numeric, p_starts_at timestamptz, p_ends_at timestamptz) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_role('hub_admin');
  v_id uuid;
begin
  if length(btrim(coalesce(p_name, ''))) < 3 then perform app.fail('invalid_name', 'Dê um nome à regra.'); end if;
  if p_scope not in ('category', 'provider', 'campaign') then perform app.fail('invalid_scope', 'Escolha o tipo da regra.'); end if;
  if p_percent is null or p_percent not between 0 and 60 then perform app.fail('invalid_commission', 'A comissão deve ficar entre 0% e 60%.'); end if;
  if p_scope = 'category' and not exists (select 1 from public.service_categories where code = p_category_code) then
    perform app.fail('invalid_category', 'Escolha a categoria.');
  end if;
  if p_scope = 'provider' and not exists (select 1 from public.providers where id = p_provider_id) then perform app.fail('invalid_provider', 'Escolha o prestador.'); end if;
  if p_scope = 'campaign' and (p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at) then
    perform app.fail('invalid_period', 'Uma campanha precisa de início e fim.');
  end if;
  insert into public.commission_rules (name, scope, category_code, provider_id, percent, starts_at, ends_at, created_by)
  values (btrim(p_name), p_scope, nullif(p_category_code, ''), case when p_scope = 'provider' then p_provider_id end,
    round(p_percent, 2), coalesce(p_starts_at, now()), p_ends_at, v_uid)
  returning id into v_id;
  return v_id;
end $$;

create function public.admin_end_commission_rule(p_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  update public.commission_rules set active = false, ends_at = least(coalesce(ends_at, now()), now()) where id = p_id and active;
  if not found then perform app.fail('not_found', 'Regra não encontrada ou já encerrada.'); end if;
end $$;

-- Histórico de preços, promoções, comissões e regras gerais.
create function public.admin_price_history(p_limit integer default 100) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_any_staff();
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'at', a.at, 'actor', pf.full_name, 'action', a.action,
      'entity', a.entity, 'entity_id', a.entity_id, 'before', a.before, 'after', a.after) order by a.id desc)
    from (select * from public.audit_logs where entity in ('services', 'service_prices', 'promotions', 'commission_rules', 'settings', 'regions', 'service_categories')
      order by id desc limit greatest(1, least(p_limit, 500))) a
    left join public.profiles pf on pf.id = a.actor_id), '[]'::jsonb);
end $$;

-- Equipe: papéis internos.
create function public.admin_staff() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_role('hub_admin');
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.full_name,
      'roles', coalesce((select jsonb_agg(s.role order by s.role) from public.staff_roles s where s.user_id = p.id), '[]'::jsonb)) order by p.full_name)
    from public.profiles p where p.role = 'hub_admin'), '[]'::jsonb);
end $$;

create function public.admin_set_staff_role(p_user_id uuid, p_role text, p_grant boolean) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := app.require_role('hub_admin');
begin
  if p_role not in ('admin', 'finance') then perform app.fail('invalid_role', 'Papel inválido.'); end if;
  if not exists (select 1 from public.profiles where id = p_user_id and role = 'hub_admin') then perform app.fail('not_staff', 'Esta pessoa não é da equipe.'); end if;
  if p_grant then
    insert into public.staff_roles (user_id, role, granted_by) values (p_user_id, p_role, v_uid) on conflict do nothing;
  else
    if (select count(*) from public.staff_roles where role = p_role and user_id <> p_user_id) = 0 then
      perform app.fail('last_holder', 'É preciso manter ao menos uma pessoa com este papel.');
    end if;
    delete from public.staff_roles where user_id = p_user_id and role = p_role;
  end if;
end $$;

create function public.admin_new_setup_code(p_role text default 'admin') returns text
language plpgsql security definer set search_path = ''
as $$
declare v_code text := upper(encode(extensions.gen_random_bytes(10), 'hex'));
begin
  perform app.require_role('hub_admin');
  if p_role not in ('admin', 'finance') then perform app.fail('invalid_role', 'Papel inválido.'); end if;
  update public.settings set setup_code_hash = encode(extensions.digest(v_code, 'sha256'), 'hex'), setup_code_role = p_role;
  return v_code;
end $$;

create or replace function public.claim_hub_admin(p_code text, p_full_name text, p_phone text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.uid();
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_hash text := encode(extensions.digest(upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')), 'sha256'), 'hex');
  v_role text;
begin
  if exists (select 1 from public.profiles where id = v_uid) then perform app.fail('profile_exists', 'Esta conta já tem cadastro.'); end if;
  if length(btrim(coalesce(p_full_name, ''))) < 3 then perform app.fail('invalid_name', 'Informe o nome completo.'); end if;
  if v_phone !~ '^[0-9]{10,13}$' then perform app.fail('invalid_phone', 'Informe um telefone com DDD.'); end if;
  update public.settings set setup_code_hash = null where setup_code_hash = v_hash returning setup_code_role into v_role;
  if v_role is null then perform app.fail('invalid_code', 'Código de ativação inválido ou já utilizado.'); end if;
  insert into public.profiles (id, full_name, phone, role) values (v_uid, btrim(p_full_name), v_phone, 'hub_admin');
  insert into public.staff_roles (user_id, role) values (v_uid, v_role);
end $$;

create or replace function public.promote_hub_admin(p_email text, p_full_name text, p_phone text) returns void
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
  -- Conta de implantação: acesso completo (operação e financeiro).
  insert into public.staff_roles (user_id, role) values (v_id, 'admin'), (v_id, 'finance') on conflict do nothing;
end $$;

commit;

-- >>> 20261117000600_finance_data.sql
-- =============================================================================
-- Zé do Carro — 10 Financeiro: dados iniciais e privilégios
-- Valores de PARTIDA, ajustáveis pela HUB no painel, sem nova versão do app.
-- =============================================================================

insert into public.service_categories (code, name, sort) values
  ('pneus', 'Pneus e rodas', 10),
  ('manutencao', 'Manutenção rápida', 20),
  ('emergencia', 'Socorro e emergência', 30),
  ('higienizacao', 'Limpeza e higienização', 40)
on conflict (code) do nothing;

update public.services set category_code = case code
    when 'troca_pneu' then 'pneus'
    when 'balanceamento' then 'pneus'
    when 'alinhamento' then 'pneus'
    when 'troca_oleo' then 'manutencao'
    when 'higienizacao_basica' then 'higienizacao'
    else 'manutencao' end
where category_code is null;

-- Abastecimento emergencial: entra DESATIVADO. A HUB define o preço (a taxa do
-- deslocamento; o combustível é cobrado à parte como adicional aprovado) e
-- confere as exigências de transporte de combustível antes de ativar.
insert into public.services (code, name, description, base_price, est_minutes, active, sort, category_code)
values ('abastecimento_emergencial', 'Abastecimento emergencial',
  'Levamos uma pequena quantidade de combustível até o carro parado por pane seca. O combustível é cobrado à parte, com a sua aprovação.',
  60.00, 40, false, 60, 'emergencia')
on conflict (code) do nothing;

alter table public.services alter column category_code set not null;

insert into public.regions (code, name, uf, center_lat, center_lng, radius_km)
values ('sao_luis', 'São Luís e região metropolitana', 'MA', -2.5307, -44.3068, 40)
on conflict (code) do nothing;
update public.settings set default_region_id = (select id from public.regions where code = 'sao_luis') where default_region_id is null;

-- =============================================================================
-- Privilégios. Funções novas: execução para usuários autenticados, exceto as do
-- servidor do aplicativo (só service_role). Toda função confere o papel de novo.
-- =============================================================================
revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
revoke all on all routines in schema public from public, anon, authenticated, service_role;
revoke all on all routines in schema app from public, anon, authenticated, service_role;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' loop
    if f.proname in ('promote_hub_admin', 'push_take', 'push_gone', 'check_rate_limit', 'clear_rate_limit',
        'payment_customer_linked', 'payment_charge_created', 'payment_charge_failed', 'payment_sync', 'payments_to_reconcile',
        'payment_remote_cancelled', 'webhook_record', 'webhook_done', 'webhooks_to_retry', 'refund_claim', 'refund_result',
        'payout_claim', 'payout_transfer_created', 'payout_attempt_failed', 'payout_sync_transfer', 'payouts_to_reconcile',
        'payout_validate_transfer', 'email_claim', 'email_result', 'finance_tick') then
      execute format('grant execute on function %s to service_role', f.sig);
    else
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;

commit;
