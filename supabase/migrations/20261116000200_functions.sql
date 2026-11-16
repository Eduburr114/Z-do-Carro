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
