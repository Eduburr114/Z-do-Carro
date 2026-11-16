# Zé do Carro

Aplicativo de serviços automotivos móveis, no modelo de plataforma: o **cliente** pede um serviço para o carro onde ele estiver, um **prestador credenciado** aceita e executa, e a **HUB** (HUB Tecnologia e Serviços Automotivos Ltda.) credencia, intermedia o pagamento e cuida da qualidade.

Uma única aplicação web instalável no celular (PWA), com três áreas:

| Área | Quem usa | O que faz |
|---|---|---|
| `/cliente` | Motorista | Cadastra o veículo, pede o serviço com preço fechado, acompanha as etapas e o prestador no mapa, aprova ou recusa adicionais, paga e avalia |
| `/prestador` | Profissional autônomo ou empresa | Envia documentos e o credenciamento, aceita o contrato, fica disponível quando quer, aceita ou recusa pedidos vendo o valor líquido, executa e acompanha os ganhos |
| `/hub` | Equipe da HUB | Analisa documentos e credenciamentos serviço a serviço, suspende com motivo e revê contestações, confirma pagamentos por Pix, registra repasses, ajusta preços, comissão e a equipe |

Também há, para todos: avisos dentro do aplicativo e por push, tela de conta, recuperação de senha por e-mail, Termos de Uso e Política de Privacidade (minutas) com aceite gravado no cadastro.

> **Situação:** completo e testado localmente; ainda não publicado. Leia [o que falta antes de operar](#o-que-falta-antes-de-operar-com-clientes-reais).

## Como o contrato de credenciamento virou regra do sistema

O texto da minuta 1.0 está em `supabase/contracts/credenciamento-v1.0.txt` e é publicado no banco pela migração de dados iniciais. As cláusulas que dependem de comportamento do aplicativo foram implementadas assim:

| Cláusula | No aplicativo |
|---|---|
| 3.1, 3.2, 3.5 — autonomia e conexão por iniciativa do prestador | O botão "Ficar disponível" é a única forma de receber pedidos. Não há escala, jornada, meta nem aviso por ficar indisponível |
| 3.3, 10.3 — recusar não gera punição | A recusa só tira o pedido da lista daquele prestador. A nota vem exclusivamente das avaliações dos clientes; recusas e tempo conectado não entram em nenhum cálculo |
| 4 — credenciamento e qualificação | O credenciamento exige documento de identificação e aceita certificados e fotos de equipamentos. O prestador só vê pedidos depois da aprovação da HUB, e cada serviço é habilitado separadamente |
| 6.1, 7.3 — remuneração líquida antes do aceite | Toda oferta mostra preço ao cliente, comissão e "Você recebe". A comissão fica congelada no pedido |
| 6.5 — adicionais com orçamento e autorização | O prestador envia o orçamento pelo app, o cliente aprova ou recusa, e o serviço não pode ser concluído com orçamento pendente |
| 7.4 — pagamento intermediado | O cliente paga à HUB (Pix com confirmação manual, ou simulado no modo demonstração) e a HUB registra o repasse ao prestador |
| 7.2, 7.5 — comissão e prazo de repasse | Configurados em Ajustes; as condições vigentes ficam registradas junto com cada aceite do contrato |
| 11 — suspensão com motivo e contestação | A suspensão exige motivo escrito, que o prestador vê; ele contesta pelo app e a HUB registra a revisão fundamentada |
| 12.2, 12.4 — dados mínimos e localização | Nome, telefone e placa do cliente só aparecem para o prestador depois do aceite. A posição do prestador só é guardada enquanto ele está disponível ou em atendimento. Documentos só abrem para o próprio prestador e para a HUB |
| 14.2 — encerramento | O prestador encerra o próprio credenciamento quando quiser, desde que não haja atendimento em andamento |
| 15.1 — aceite eletrônico | O aceite grava nome, documento, data e hora, IP, navegador e o SHA-256 do texto aceito |
| 15.2 — novas versões | Publicada uma nova versão vigente, o prestador precisa aceitá-la para voltar a receber pedidos |

## Pilha

Next.js 16 (App Router, Server Components e Server Actions), React 19, TypeScript, Tailwind CSS 4, Supabase (PostgreSQL e Auth), Web Push e Leaflet com OpenStreetMap.

A regra central é: **o banco decide**. Nenhuma tabela é acessível direto pela API; tudo passa por funções que conferem quem chama e o papel (`supabase/migrations`). Os tokens de sessão ficam em cookies `httpOnly` e não há cliente Supabase no navegador. A chave secreta do Supabase é usada no servidor só para o limite de tentativas e para a fila de push.

## Rodar no computador (sem Docker)

Requisitos: Node.js 22+, pnpm 10 e PostgreSQL 16 local em `postgres://postgres:postgres@127.0.0.1:5432` (ou defina `LOCAL_PG_ADMIN_URL`).

```bash
pnpm install
./scripts/dev-local.sh      # recria o banco local, sobe o emulador do Supabase e o Next.js
```

Abra http://localhost:3000. Contas fictícias (senha `demonstracao-local-2026`):

| E-mail | Papel |
|---|---|
| `cliente@demo.invalid` | Cliente com um veículo |
| `ze@demo.invalid` | Prestador credenciado, com contrato aceito |
| `novato@demo.invalid` | Prestador aguardando análise |
| `hub@demo.invalid` | Equipe da HUB |

Para ver o fluxo, abra duas janelas: peça um serviço como cliente e, na outra, entre como `ze@demo.invalid` e toque em "Ficar disponível". O emulador não envia e-mails: o link de recuperação de senha aparece no terminal.

## Testes

```bash
pnpm test                    # 25 testes de banco: acesso, credenciamento, documentos, contrato, atendimento, Pix, avisos, suspensão
pnpm build && pnpm test:e2e  # 3 roteiros no navegador, com cliente, prestador e HUB ao mesmo tempo
pnpm check                   # lint, tipos, testes de banco e build
```

Os testes de banco chamam as funções como a API faria (papel `authenticated` e claims do JWT), nunca como superusuário. O `.github/workflows/ci.yml` roda tudo a cada push.

## Implantação

1. **Supabase.** Crie um projeto (região São Paulo, `sa-east-1`) e instale o banco: cole o conteúdo de `supabase/instalar.sql` no editor SQL e execute (ou use `supabase db push`, que aplica as migrações de `supabase/migrations`). Em Authentication:
   - **URL Configuration:** defina a *Site URL* com o endereço do aplicativo e inclua `https://SEU-ENDERECO/auth/confirmar` nas *Redirect URLs*.
   - **Email Templates → Reset Password:** use o link `{{ .SiteURL }}/auth/confirmar?token_hash={{ .TokenHash }}&type=recovery`, para a recuperação funcionar em qualquer aparelho.
   - **Confirmação de e-mail e SMTP:** o envio de e-mail embutido do Supabase aceita pouquíssimas mensagens por hora. Para operar, configure um SMTP próprio. Sem ele, desligue *Confirm email* para o cadastro não depender de e-mail.
2. **Vercel.** Importe o repositório e defina as variáveis de `.env.example`. O `vercel.json` já fixa a região `gru1` (São Paulo), ao lado do banco.
3. **Avisos push.** Gere o par de chaves com `pnpm exec web-push generate-vapid-keys` e preencha as três variáveis `VAPID`.
4. **Primeiro acesso da HUB.** No editor SQL, grave um código de ativação (letras maiúsculas e números):

   ```sql
   update public.settings set setup_code_hash = encode(extensions.digest('TROQUEESTECODIGO2026', 'sha256'), 'hex');
   ```

   Depois abra `/cadastro?tipo=hub` e crie a conta informando o código. Ele vale uma única vez; os próximos acessos da equipe são gerados em Ajustes.
5. **Recebimento.** Em Ajustes, cadastre a chave Pix da HUB. Sem ela o aplicativo fica em modo demonstração, com pagamento simulado.

## O que falta antes de operar com clientes reais

- **Revisão jurídica.** O contrato publicado é a minuta 1.0, com `[CNPJ]`, `[endereço]`, `[PERCENTUAL]` e `[PRAZO]` por preencher; as linhas de assinatura em papel foram omitidas porque o aceite é eletrônico. Os Termos de Uso e a Política de Privacidade também são minutas, com campos entre colchetes. Ao fechar os textos, publique o contrato como nova versão e atualize `src/lib/terms.ts`.
- **Provedor de pagamentos.** O Pix com confirmação manual serve a um piloto. Para volume, integre um provedor com cobrança e divisão automáticas; as funções `pay_request`, `claim_payment` e `admin_confirm_payment` são o ponto de troca.
- **Preços e comissão.** Os preços do catálogo, a comissão de 20% e o repasse em 7 dias são valores de partida, não uma recomendação comercial.
- **Push em aparelhos reais.** O envio foi testado até a fila do servidor; falta conferir a entrega em um Android e em um iPhone (no iPhone, só com o aplicativo instalado na Tela de Início, iOS 16.4 ou mais novo).
- **Mapa.** Usa os quadros públicos do OpenStreetMap, adequados a baixo volume. Para escala, contrate um provedor de mapas.
- **Documentos.** Ficam no banco de dados (até 3 MB cada, 12 por prestador). Com muitos prestadores, mova para um armazenamento de arquivos.
