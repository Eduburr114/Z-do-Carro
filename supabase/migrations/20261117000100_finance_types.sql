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
