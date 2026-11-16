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
