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
