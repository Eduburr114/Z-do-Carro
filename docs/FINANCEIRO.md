# Módulo financeiro do Zé do Carro

Este documento cobre os pagamentos, os repasses, os e-mails e a segurança. Ele explica como cada parte funciona, como configurar e o que falta conferir antes de operar com dinheiro real.

## 1. Diagnóstico (antes desta etapa)

- **Pagamento:** o cliente pagava **depois** do serviço. Havia dois modos:
  - *Demonstração:* o próprio cliente marcava o pedido como pago. Isso fere a regra de nunca confirmar pagamento pelo aplicativo do cliente.
  - *Pix manual:* a HUB confirmava o recebimento sem registrar o identificador da transação.
- **Repasse:** era marcado à mão, sem razão contábil, sem idempotência, sem webhook e sem conciliação.
- **Regras e catálogo:** comissão e prazo eram configuráveis, mas só valia uma comissão global. O preço era único, sem região, promoção nem histórico.
- **E-mail:** só o SMTP embutido do Supabase (poucas mensagens por hora).
- **O que já era sólido e foi mantido:**
  - RLS ligado sem políticas, com acesso só por funções `security definer` que conferem o papel.
  - Sessão em cookies `httpOnly`.
  - Valores em `numeric(12,2)`.
  - Comissão congelada no pedido.
  - Limite de tentativas no login.

## 2. Decisões de arquitetura

| Decisão | Motivo |
|---|---|
| **Pagamento antes do atendimento** (mudança de regra) | O pedido só é oferecido aos prestadores depois que o provedor confirma o Pix. Isso elimina a inadimplência depois do serviço e os pedidos falsos, e permite reter o valor até a conclusão confirmada. Se o cliente cancelar antes do início do serviço, o estorno é integral e automático. |
| **Cobrança sem split + transferência programada** | A documentação do Asaas diz que o split é executado no recebimento, sem data personalizada, e recomenda não usar split quando o repasse depende de data futura ou de aprovação posterior. O repasse em 7 dias, portanto, é uma transferência Pix feita pelo nosso processador na data devida. |
| **Estado oficial vem da API do provedor** | O webhook só avisa que algo mudou. O servidor consulta `GET /payments/{id}` (ou `/transfers/{id}`) e aplica esse estado. Um webhook forjado, mesmo com o token, não confirma nada. |
| **Centavos inteiros** nas tabelas novas | `bigint` em `payments`, `payouts`, `refunds` e `financial_ledger`. As colunas antigas continuam em `numeric(12,2)`, que também é exato. |
| **Razão em partidas dobradas, somente inclusão** | Gatilhos impedem alteração e exclusão. Um gatilho diferido recusa jornal desbalanceado. |
| **Tudo pelo banco** | Cada operação financeira é uma função transacional que confere o papel. O frontend nunca decide valor nem estado. |

## 3. Máquina de estados financeira (`requests.financial_status`)

```
pending_payment ──► payment_confirmed ──► service_in_progress ──► service_completed ──► payout_scheduled ──► payout_processing ──► payout_completed
      │                    │                      │                      │      ▲              │      ▲               │
      ▼                    ▼                      ▼                      ▼      │              ▼      │               ▼
  cancelled          refund_pending ◄───────────────────────────── disputed ───┘         payout_failed ─┘        payout_failed
                           │
                           ▼
                        refunded
```

- **Onde a transição é validada:** no gatilho `app.guard_request`. Toda transição passa por `app.fin_allowed`, venha de onde vier, e fica gravada em `financial_events`.
- **Conclusão confirmada:** o cliente confirma, ou a confirmação é automática depois de `confirm_hours`, sem disputa aberta. Nesse momento a receita é reconhecida e o repasse é agendado para `payout_days` dias depois.
- **Disputa:** retém o repasse. A equipe financeira decide.
  - A favor do cliente: estorno integral.
  - A favor do prestador: o repasse é agendado.
- **Estorno depois do repasse:** gera conta a receber do prestador (`provider_receivable`).

## 4. Tabelas

| Pedido no prompt | Tabela no projeto |
|---|---|
| `platform_settings` | `settings` (já existia), com novas colunas financeiras |
| `services_catalog` | `services` mais `service_categories`, `regions`, `service_prices` e `promotions` |
| `service_orders` | `requests` (já existia), com cópia imutável de preço, desconto, taxa, comissão e prazo |
| `provider_payment_accounts` | `provider_payment_accounts` |
| `payments` | `payments` (e `payment_customers`, com o CPF/CNPJ separado do perfil) |
| `financial_ledger` | `financial_ledger` |
| `payouts` | `payouts` (e `payout_attempts`) |
| `webhook_events` | `webhook_events` |
| `audit_logs` | `audit_logs` |
| `notification_logs` | `notification_logs` (fila e registro dos e-mails) |
| — | `commission_rules`, `refunds`, `disputes`, `financial_events`, `staff_roles`, `withdrawal_authorizations` |

As migrações são versionadas em `supabase/migrations/20261117000100…600`. Para um projeto Supabase novo, rode `supabase/instalar.sql`, que é gerado por `scripts/gerar-instalacao.sh` e faz `COMMIT` entre os arquivos.

## 5. Comissões e preços

**Comissão aplicada:** prestador > campanha > categoria > padrão.

- **Na criação do pedido:** registra a comissão padrão, de categoria ou de campanha.
- **No aceite (a contratação):** só uma regra específica do prestador pode substituí-la. A oferta já mostra o líquido do prestador.
- **Depois do aceite:** a comissão não muda mais. O gatilho bloqueia a alteração.
- **Regras imutáveis:** uma regra não se edita; encerra-se e cria-se outra.

**Preço:**

- Vale o preço da região ou, se não houver, o de tabela, menos a melhor promoção vigente, mais a taxa da plataforma.
- O total nunca fica abaixo da cobrança mínima.
- O cliente vê o total antes de confirmar.
- O desconto é custeado pela plataforma: o líquido do prestador é calculado sobre o preço de tabela. Por isso a receita pode ficar negativa e ir para `promotion_subsidy`.

O histórico de preços, promoções, regras e ajustes fica em `audit_logs`, com o autor, e aparece em **Ajustes → Catálogo e preços**.

**Valores iniciais:**

- Comissão de 20%.
- Repasse 7 dias depois da conclusão confirmada.
- Confirmação automática em 24 h.
- Prazo de pagamento de 30 min.
- Taxa ao cliente de R$ 0.
- Cobrança mínima de R$ 5 (confira o mínimo vigente do Asaas).
- Carência de 24 h para conta Pix nova.
- Região padrão: São Luís, raio de 40 km.
- **Abastecimento emergencial:** entra **desativado**. A HUB define o preço e confere as exigências de transporte de combustível antes de ativar.

## 6. Fluxos técnicos

### Cobrança Pix

1. `payment_start` (cliente) valida o pedido, decide o valor no banco e cria `payments` com uma `attempt_key` única. É idempotente: se já houver cobrança aberta, devolve a mesma.
2. O servidor, com a chave secreta:
   - cria o cliente no Asaas (`POST /v3/customers`) e a cobrança (`POST /v3/payments`, `billingType: PIX`, `externalReference = attempt_key`);
   - busca o QR Code (`GET /v3/payments/{id}/pixQrCode`);
   - registra tudo com `payment_charge_created`.
3. Se a resposta se perder, a cobrança fica `creating`. A rotina procura a cobrança pela `externalReference` e não cobra em dobro.
4. Pagamentos que chegam fora do fluxo (atrasados, duplicados ou com valor divergente) ficam marcados como órfãos e são estornados automaticamente.

### Webhook (`POST /api/webhooks/asaas`)

1. Confere o cabeçalho `asaas-access-token` em tempo constante. Token errado é recusado e limitado por origem (429).
2. Valida o formato do evento (até 256 KB).
3. Grava o evento em `webhook_events`, com unicidade por `(provider, event_id)`. Repetição de evento já processado responde `200 duplicate`.
4. Consulta o recurso oficial e aplica o estado com `payment_sync` ou `payout_sync_transfer`. Essas funções são idempotentes e só avançam: um evento fora de ordem não faz nada regredir.
5. Responde 200 assim que o evento está gravado. Se o processamento falhar, a rotina tenta de novo até 10 vezes. O Asaas pausa a fila de quem responde erro.

### Repasse

1. `payout_claim` reserva os repasses vencidos com `FOR UPDATE SKIP LOCKED` e troca o estado na mesma transação, com um `claim_token` por tentativa.
2. O repasse só sai com:
   - conta Pix ativa, conferida pela equipe e fora da carência;
   - nenhuma disputa aberta.
3. `POST /v3/transfers` com `pixAddressKey`, `pixAddressKeyType` e `externalReference = payout_id`.
4. **Sem resposta do provedor** (tempo esgotado ou 5xx): o repasse fica `processing` + `uncertain` e **não é tentado de novo** até a conciliação.
5. **Falha definitiva:** nova tentativa com espera crescente (5 min, 10 min… até 12 h). Ao atingir `payout_max_attempts`, vira falha final e gera alerta à equipe e e-mail ao prestador.
6. **Proteções contra repasse em dobro:**
   - um repasse por pedido (`unique(request_id)`);
   - estado trocado com a linha travada;
   - token de reserva;
   - `external_id` único;
   - o razão debita `provider_payable` uma única vez;
   - o **mecanismo de validação de saque** (abaixo).

### Mecanismo de validação de saque (`POST /api/webhooks/asaas/saque`)

1. O Asaas pergunta antes de executar **cada** transferência da conta.
2. Respondemos `APPROVED` só para:
   - um repasse em processamento, com o mesmo valor e a mesma chave, e que ainda não tenha outra transferência vinculada;
   - ou um saque autorizado pela equipe financeira (valor exato, válido por 30 min).
3. Qualquer outra transferência recebe `REFUSED`, inclusive uma criada com a chave de API vazada. Em qualquer erro, também recusamos.
4. Com o mecanismo ligado, um repasse "incerto" sem transferência vinculada depois de 30 min é dado como não feito e volta para nova tentativa sem risco.

### Rotina periódica (`GET|POST /api/cron/financeiro`, `Authorization: Bearer CRON_SECRET`)

Cada rodada faz, nesta ordem:

1. Prazos de pagamento e confirmação automática.
2. Retenção de dados.
3. Conciliação de cobranças: webhook perdido, criação interrompida, QR Code faltando, remoção de cobranças canceladas.
4. Webhooks com erro.
5. Estornos.
6. Repasses.
7. Conciliação de transferências.
8. Fila de e-mails.
9. Push.

Pode rodar em paralelo sem duplicar nada. **Agende a cada 5 minutos.** Recomendação: Supabase Cron (`pg_cron` + `pg_net`). Confira os nomes das funções na documentação do Supabase do seu projeto:

```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;
select vault.create_secret('<CRON_SECRET>', 'ze_cron_secret');
select cron.schedule('ze-financeiro', '*/5 * * * *', $$
  select net.http_post(
    url := 'https://ze-do-carro.fly.dev/api/cron/financeiro',
    headers := jsonb_build_object('Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'ze_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000);
$$);
```

Alternativa: uma máquina agendada do Fly.io. Ela tem intervalo mínimo de 1 h, o que deixa prazos de 30 min menos precisos.

## 7. Configurar o Asaas (sandbox primeiro)

1. Crie a conta de sandbox em `sandbox.asaas.com` e gere a chave de API. Ela vai em `ASAAS_API_KEY`, com `ASAAS_ENV=sandbox`.
   - Dê à chave só as permissões necessárias: cobranças, clientes, estornos (`PAYMENT_REFUND:WRITE`), transferências e saldo.
2. **Webhooks → Novo webhook**, apontando para `https://SEU-DOMINIO/api/webhooks/asaas`:
   - envio sequencial;
   - eventos de **cobrança** (`PAYMENT_*`) e de **transferência** (`TRANSFER_*`);
   - token de autenticação igual a `ASAAS_WEBHOOK_TOKEN` (32 a 255 caracteres; gere com `openssl rand -hex 32`).
   - O Asaas não segue redirecionamentos: use a URL final, com https.
3. **Mecanismo de validação de saque** (Integrações / Segurança): aponte para `https://SEU-DOMINIO/api/webhooks/asaas/saque` com o token `ASAAS_TRANSFER_VALIDATION_TOKEN`.
   - Depois de ligado, **todo** saque precisa ser repasse conhecido ou autorizado em **Financeiro → Conciliação → Saque da HUB**.
4. Defina `CRON_SECRET` e o agendador (seção 6).
5. Teste no sandbox:
   - pague a cobrança pelo botão de confirmar pagamento do painel de sandbox ou pelo endpoint de sandbox de confirmação;
   - confira o pedido virar "Procurando prestador";
   - faça um repasse de teste para uma chave Pix de teste;
   - faça um estorno.
6. **Antes da produção, confira no sandbox o que está marcado como "confirmar"** em `src/lib/payments/asaas.ts`:
   - o caminho do estorno;
   - o filtro `externalReference` na listagem de cobranças;
   - o campo `externalReference` e a tarifa (`transferFee`) nas transferências;
   - o formato do corpo da validação de saque;
   - `GET /v3/finance/balance`.
7. **Produção:** chave de produção, `ASAAS_ENV=production`, webhooks recadastrados na conta de produção.
   - Confirme com o Asaas se o modelo funciona para a sua conta: a HUB recebe em conta própria e repassa a terceiros em D+7.
   - Confirme limites de transferência, tarifas e exigências cadastrais e regulatórias, inclusive se a atividade de intermediação exige estrutura de subcontas ou conta escrow. **Não ative em produção sem essa confirmação.**

Sem `ASAAS_API_KEY`, use **Ajustes → Recebimento: Pix manual**. O cliente paga para a chave da HUB, e só a equipe financeira confirma, com o identificador E2E da transação. Esse identificador não pode ser reutilizado.

## 8. E-mails (Supabase Auth + Resend)

### Autenticação: SMTP próprio no Supabase

Supabase → **Authentication → SMTP Settings**:

- host `smtp.resend.com`, porta `465`;
- usuário `resend`, senha = uma chave de API do Resend (de preferência uma chave só para SMTP);
- remetente de domínio verificado.

**Modelos em português** (cole o HTML em *Authentication → Email Templates*):

| Modelo | Arquivo | Link usado |
|---|---|---|
| Confirm signup | `supabase/templates/confirmacao-cadastro.html` | `/auth/confirmar?token_hash={{ .TokenHash }}&type=email` |
| Reset password | `supabase/templates/recuperacao-senha.html` | `/auth/confirmar?token_hash={{ .TokenHash }}&type=recovery` |
| Change email address | `supabase/templates/troca-email.html` | `/auth/confirmar?token_hash={{ .TokenHash }}&type=email_change` |

Em *URL Configuration*, defina a **Site URL** como o domínio do app e inclua `https://SEU-DOMINIO/auth/confirmar` nas Redirect URLs.

### Transacionais: API do Resend

- **Configuração:** `RESEND_API_KEY` e `EMAIL_FROM` (domínio verificado). A chave fica só no servidor.
- **Modelos:** `src/lib/email/templates.ts`, todos com HTML responsivo e versão texto.

| Modelo | Quando sai |
|---|---|
| `pagamento_confirmado` | Pagamento do pedido confirmado |
| `servico_concluido` | Prestador concluiu; pede confirmar ou contestar |
| `repasse_agendado` | Repasse agendado |
| `repasse_realizado` | Repasse transferido |
| `repasse_falhou` | Repasse com falha definitiva |
| `estorno_realizado` | Estorno concluído |
| `conta_pix_alterada` | Conta Pix do prestador alterada (aviso de segurança) |
| `alerta_financeiro` | Alertas à equipe financeira |

**Outbox transacional:** o e-mail entra em `notification_logs` na **mesma transação** do fato que o motiva. Depois da resposta (e na rotina), o servidor envia.

**Idempotência:** cada envio leva o cabeçalho `Idempotency-Key` com a chave da fila, o mesmo que o SDK oficial do Resend usa. Repetir o envio não gera e-mail novo.

**Novas tentativas:**

| Situação | O que acontece |
|---|---|
| 429, 5xx ou sem resposta | Volta para a fila com espera de 1 min, 5 min, 30 min, 2 h e 6 h. Depois de 6 tentativas, falha. |
| Outros 4xx (endereço inválido, domínio não verificado) | Falha definitiva, registrada. |
| Sem chave configurada | Marcado como `skipped`, nunca como enviado. |

**Limites:** a base de conhecimento do Resend indica 10 requisições por segundo por equipe; o limite real da sua conta aparece nos cabeçalhos `ratelimit` de cada resposta. A cota diária e mensal depende do plano. A fila envia em lotes de até 25 por rodada.

### DNS do domínio de envio

Copie **exatamente** os registros que o painel do Resend mostrar para o seu domínio. Em geral são:

- **DKIM:** registro TXT em `resend._domainkey` com a chave pública fornecida.
- **SPF:** no subdomínio de envio indicado (ex.: `send`), um MX de retorno e um TXT `v=spf1 include:… ~all`, como mostrado no painel.
- **DMARC:** TXT em `_dmarc` com `v=DMARC1; p=none; rua=mailto:dmarc@seu-dominio.com.br`. Depois de algumas semanas de relatórios limpos, suba para `p=quarantine` e então `p=reject`.

Use um subdomínio (ex.: `avisos.seu-dominio.com.br`) para isolar a reputação do e-mail corporativo.

## 9. Segurança

| Exigência | Como está atendida |
|---|---|
| RLS | Ligado em todas as tabelas, **sem políticas**: nenhuma linha é lida ou escrita direto pela API. Todo acesso passa por funções que conferem `auth.uid()` e o papel. |
| Papéis | Cliente, prestador, **administrador** (`staff_roles.admin`) e **gestor financeiro** (`staff_roles.finance`). O gestor financeiro não altera preço nem comissão; o administrador não vê dados financeiros detalhados nem executa estorno ou repasse (a menos que tenha os dois papéis). |
| Segregação de dados | CPF de cobrança fica em `payment_customers`, separado do perfil. Chave Pix completa só a equipe financeira vê; o prestador vê mascarada. QR Code só para o próprio cliente. |
| Autorização no backend | Toda RPC confere o papel. As funções do servidor (webhook, repasse, fila) só aceitam `service_role`, ou seja, só com a chave secreta. |
| Auditoria | Gatilhos em regras, preços, promoções, comissões, contas Pix, repasses, estornos, equipe e autorizações de saque. Validações de saque também ficam registradas. Os registros são somente de inclusão. |
| Chaves e tokens | Só em variáveis de ambiente do servidor. `server-only` impede import no navegador. `ASAAS_BASE_URL` e `RESEND_BASE_URL` só aceitam o emulador local. |
| Validação de entrada | Zod nas Server Actions, mais validação no banco (CPF/CNPJ com dígitos verificadores, chave Pix por tipo, faixas de valores). |
| Rate limiting | Login e recuperação (já existiam); criação de pedido, cobrança, CPF, disputa, troca de conta Pix (3 por dia), estornos da equipe; webhook com token inválido. |
| Contas recebedoras | Precisam ter o CPF/CNPJ do credenciamento. Passam por conferência da equipe financeira e por carência configurável. O prestador recebe aviso por e-mail e no app. Com a validação de saque, nenhuma transferência vai para chave diferente da conferida. |
| Webhooks | Token em tempo constante, idempotência por id, estado obtido da API (resiste a falsificação e repetição) e transições monotônicas (resistem a eventos fora de ordem). |
| IDOR | Toda função filtra pelo dono (`customer_id = auth.uid()`, `provider_id = auth.uid()`) ou exige papel da equipe. Testado. |
| LGPD | Finalidade declarada na Política de Privacidade (atualizada) e minimização automática na rotina: QR Code apagado 1 dia depois de a cobrança fechar; e-mail e conteúdo de envios apagados em 180 dias; conteúdo de webhooks apagado em 180 dias. Registros financeiros mantidos pelo prazo fiscal. **Pendente:** prazos finais com o jurídico e um processo de atendimento a pedidos de titulares. |

## 10. Testes executados

| Comando | O que cobre |
|---|---|
| `pnpm test` | Banco e integração: 73 testes |
| `pnpm test:e2e` | Navegador: 3 roteiros |

**`tests/db/financeiro.test.ts`:**

- permissões e segregação;
- CPF;
- idempotência da cobrança;
- Pix confirmado e não confirmado (prazo vencido);
- pagamento atrasado, duplicado e com valor divergente;
- webhook repetido e cobrança desconhecida;
- eventos fora de ordem;
- estorno e falha de estorno;
- preço por região, promoção e taxa;
- alteração de preço sem efeito retroativo;
- comissão por categoria, campanha e prestador;
- agendamento do repasse em 7 dias;
- confirmação automática;
- disputas;
- conta Pix e carência;
- repasse concorrente sem duplicidade;
- validação de saque;
- falha de transferência com novas tentativas e limite;
- repasse incerto e conciliação manual;
- estorno depois do repasse;
- razão imutável e balanceado;
- auditoria;
- painel;
- fila de e-mails.

**`tests/integration/financeiro.test.ts`:** cliente HTTP do Asaas contra o emulador:

- autenticação e classificação de erros;
- cobrança com QR Code;
- webhook autêntico, sem token e com conteúdo falso;
- limite de tentativas no webhook;
- webhook perdido conciliado pela rotina;
- criação sem resposta encontrada pela referência;
- estorno no provedor;
- repasse ponta a ponta com duas rodadas concorrentes (uma só transferência);
- segunda transferência e transferência intrusa recusadas;
- saque autorizado;
- falha de transferência;
- e-mails: modelos, idempotência, erro temporário e definitivo, sem provedor.

**`tests/e2e/fluxo.spec.ts`:** cliente paga o pedido e o adicional pelo Pix do emulador, a confirmação chega por webhook, o prestador executa, o cliente confirma, o prestador cadastra a chave, a equipe aprova, a rotina transfere com validação de saque, e os e-mails saem pelo emulador do Resend.

**Não testado** (depende de credenciais e acesso externo): o sandbox real do Asaas, o envio real pelo Resend, o SMTP do Supabase e o agendador em produção. Nenhum pagamento real foi feito.

## Fontes consultadas (documentação oficial)

- Asaas:
  - [Introdução aos webhooks](https://docs.asaas.com/docs/sobre-os-webhooks)
  - [Idempotência em webhooks](https://docs.asaas.com/docs/how-to-implement-idempotence-in-webhooks)
  - [Eventos para cobranças](https://docs.asaas.com/docs/webhook-para-cobrancas)
  - [Eventos para transferências](https://docs.asaas.com/docs/webhook-para-transferencias)
  - [Cobranças via Pix](https://docs.asaas.com/docs/cobrancas-via-pix)
  - [QR Code de cobrança Pix](https://docs.asaas.com/reference/obter-qr-code-para-pagamentos-via-pix)
  - [Transferência Pix/TED](https://docs.asaas.com/docs/transferencia-para-contas-de-outra-instituicao-pix-ted)
  - [Validação de saque via webhooks](https://docs.asaas.com/docs/mecanismo-para-validacao-de-saque-via-webhooks)
  - [Estorno de cobrança](https://docs.asaas.com/reference/estornar-cobranca)
  - [FAQ de split](https://docs.asaas.com/docs/duvidas-frequentes-split)
  - [Confirmar pagamento no sandbox](https://docs.asaas.com/reference/confirmar-pagamento)
- Resend:
  - [Supabase com SMTP do Resend](https://www.resend.com/docs/send-with-supabase-smtp)
  - [Limite de requisições](https://www.resend.com/docs/api-reference/rate-limit)
  - SDK oficial `resend` no npm (cabeçalho `Idempotency-Key`)

O acesso direto a `docs.asaas.com` e `resend.com` estava bloqueado na rede desta sessão. As páginas foram consultadas pelos trechos da busca, por isso os itens marcados como "confirmar" precisam ser verificados no sandbox.
