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
