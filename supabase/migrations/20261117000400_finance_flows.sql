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
