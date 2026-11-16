-- =============================================================================
-- SOMENTE DESENVOLVIMENTO/TESTE LOCAL — NÃO FAZ PARTE DAS MIGRAÇÕES.
-- Reproduz, em um PostgreSQL comum, o mínimo que o Supabase já entrega pronto:
-- papéis (anon, authenticated, service_role), schema auth e as funções
-- auth.uid() / auth.jwt(). Também copia os privilégios padrão PERMISSIVOS do
-- Supabase, para que os testes provem que as migrações os revogam de fato.
-- Em um projeto Supabase real (nuvem ou `supabase start`) este arquivo não é usado.
-- =============================================================================

do $$
begin
  if not exists (select from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

create schema if not exists extensions;
create schema if not exists auth;

grant usage on schema public, extensions, auth to anon, authenticated, service_role;

-- Privilégios padrão do Supabase: tudo liberado para os três papéis em `public`.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

-- Subconjunto do schema auth usado pelo emulador local e pelos testes.
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  encrypted_password text,
  email_confirmed_at timestamptz default now(),
  banned_until timestamptz,
  raw_app_meta_data jsonb not null default '{}'::jsonb,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  last_sign_in_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table auth.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  aal text not null default 'aal1',
  amr jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  refreshed_at timestamptz
);

create table auth.refresh_tokens (
  token text primary key,
  session_id uuid not null references auth.sessions (id) on delete cascade,
  revoked boolean not null default false,
  created_at timestamptz not null default now()
);

create table auth.mfa_factors (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  friendly_name text,
  factor_type text not null default 'totp',
  status text not null default 'unverified',
  secret text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table auth.mfa_challenges (
  id uuid primary key default gen_random_uuid(),
  factor_id uuid not null references auth.mfa_factors (id) on delete cascade,
  created_at timestamptz not null default now(),
  verified_at timestamptz
);

create or replace function auth.jwt() returns jsonb
language sql stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;

create or replace function auth.uid() returns uuid
language sql stable
as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;

create or replace function auth.role() returns text
language sql stable
as $$
  select coalesce(auth.jwt() ->> 'role', 'anon')
$$;

grant execute on function auth.jwt(), auth.uid(), auth.role() to anon, authenticated, service_role;
