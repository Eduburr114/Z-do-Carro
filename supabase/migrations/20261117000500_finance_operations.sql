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
      'attempt_key', p.attempt_key, 'status', p.status, 'remote_cancel', p.remote_cancel_pending,
      'needs_qr', p.status = 'pending' and p.pix_payload is null))
    from (select * from public.payments p
      where p.method = 'pix_asaas' and (
        (p.status in ('pending', 'refund_pending') and p.external_id is not null and p.created_at < now() - interval '1 minute'
          and (p.last_synced_at is null or p.last_synced_at < now() - interval '3 minutes'))
        or (p.status = 'pending' and p.external_id is not null and p.pix_payload is null)
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
  where used_at is null and expires_at > now() and amount_cents = p_value_cents and p_pix_key is not null
    and regexp_replace(lower(pix_key), '[^a-z0-9@._-]', '', 'g') = regexp_replace(lower(p_pix_key), '[^a-z0-9@._-]', '', 'g')
  order by created_at limit 1 for update skip locked;
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

-- Regras vigentes, para a equipe financeira (sem acesso à administração).
create function public.finance_settings() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform app.require_staff('finance');
  return (select jsonb_build_object('settings', jsonb_build_object('payment_provider', s.payment_provider, 'payout_mode', s.payout_mode,
      'commission_percent', s.commission_percent, 'payout_days', s.payout_days, 'confirm_hours', s.confirm_hours,
      'account_cooldown_hours', s.account_cooldown_hours, 'payout_max_attempts', s.payout_max_attempts)) from public.settings s);
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

create function public.finance_authorize_withdrawal(p_amount numeric, p_note text, p_pix_key text) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := app.require_staff('finance');
  v_id uuid;
begin
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then perform app.fail('invalid_amount', 'Informe um valor válido.'); end if;
  if length(btrim(coalesce(p_note, ''))) < 5 then perform app.fail('note_required', 'Informe a finalidade do saque.'); end if;
  if length(btrim(coalesce(p_pix_key, ''))) < 3 then perform app.fail('pix_key_required', 'Informe a chave Pix de destino do saque.'); end if;
  insert into public.withdrawal_authorizations (amount_cents, pix_key, note, created_by, expires_at)
  values (app.cents(p_amount), btrim(p_pix_key), btrim(p_note), v_uid, now() + interval '30 minutes') returning id into v_id;
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
