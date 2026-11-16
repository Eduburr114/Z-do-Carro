# Zé do Carro

Aplicativo de serviços automotivos móveis, no modelo de plataforma: o **cliente** pede um serviço para o carro onde ele estiver, um **prestador credenciado** aceita e executa, e a **HUB** (HUB Tecnologia e Serviços Automotivos Ltda.) credencia, intermedia o pagamento e cuida da qualidade.

Uma única aplicação web instalável no celular (PWA), com três áreas:

| Área | Quem usa | O que faz |
|---|---|---|
| `/cliente` | Motorista | Cadastra o veículo, pede o serviço com preço fechado, acompanha as etapas, aprova ou recusa adicionais, paga e avalia |
| `/prestador` | Profissional autônomo ou empresa | Envia o credenciamento, aceita o contrato, fica disponível quando quer, aceita ou recusa pedidos vendo o valor líquido, executa e acompanha os ganhos |
| `/hub` | Equipe da HUB | Analisa credenciamentos serviço a serviço, suspende com motivo e revê contestações, acompanha pedidos, registra repasses, ajusta preços e comissão |

> **Situação:** MVP funcional, testado localmente. Ainda não foi implantado. Leia [o que falta antes de operar](#o-que-falta-antes-de-operar-com-clientes-reais).

## Como o contrato de credenciamento virou regra do sistema

O texto da minuta 1.0 está em `supabase/contracts/credenciamento-v1.0.txt` e é publicado no banco pela migração de dados iniciais. As cláusulas que dependem de comportamento do aplicativo foram implementadas assim:

| Cláusula | No aplicativo |
|---|---|
| 3.1, 3.2, 3.5 — autonomia e conexão por iniciativa do prestador | O botão "Ficar disponível" é a única forma de receber pedidos. Não há escala, jornada, meta nem aviso por ficar indisponível |
| 3.3, 10.3 — recusar não gera punição | A recusa só tira o pedido da lista daquele prestador. A nota vem exclusivamente das avaliações dos clientes; recusas e tempo conectado não entram em nenhum cálculo |
| 4 — credenciamento e qualificação | O prestador só vê pedidos depois da aprovação da HUB, e cada serviço é habilitado separadamente |
| 6.1, 7.3 — remuneração líquida antes do aceite | Toda oferta mostra preço ao cliente, comissão e "Você recebe". A comissão fica congelada no pedido |
| 6.5 — adicionais com orçamento e autorização | O prestador envia o orçamento pelo app, o cliente aprova ou recusa, e o serviço não pode ser concluído com orçamento pendente |
| 7.2, 7.5 — comissão e prazo de repasse | Configurados em Ajustes; as condições vigentes ficam registradas junto com cada aceite do contrato |
| 11 — suspensão com motivo e contestação | A suspensão exige motivo escrito, que o prestador vê; ele contesta pelo app e a HUB registra a revisão fundamentada |
| 12.2, 12.4 — dados mínimos e localização | Nome, telefone e placa do cliente só aparecem para o prestador depois do aceite. A posição do prestador só é guardada enquanto ele está disponível ou em atendimento |
| 14.2 — encerramento | O prestador encerra o próprio credenciamento quando quiser, desde que não haja atendimento em andamento |
| 15.1 — aceite eletrônico | O aceite grava nome, documento, data e hora, IP, navegador e o SHA-256 do texto aceito |
| 15.2 — novas versões | Publicada uma nova versão vigente, o prestador precisa aceitá-la para voltar a receber pedidos |

## Pilha

Next.js 16 (App Router, Server Components e Server Actions), React 19, TypeScript, Tailwind CSS 4, Supabase (PostgreSQL e Auth). A regra central é: **o banco decide**. Nenhuma tabela é acessível direto pela API; tudo passa por funções que conferem quem chama e o papel (`supabase/migrations`). Os tokens de sessão ficam em cookies `httpOnly` e não há cliente Supabase no navegador.

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

Para ver o fluxo, abra duas janelas: peça um serviço como cliente e, na outra, entre como `ze@demo.invalid` e toque em "Ficar disponível".

## Testes

```bash
pnpm test        # 17 testes de banco: acesso, credenciamento, contrato, atendimento completo, suspensão
pnpm check       # lint, tipos, testes e build
```

Os testes chamam as funções como a API faria (papel `authenticated` e claims do JWT), nunca como superusuário.

## Implantação

1. **Supabase:** crie um projeto e aplique as três migrações de `supabase/migrations` em ordem (`supabase db push` ou o editor SQL). Em Authentication, decida se o e-mail precisa de confirmação; o aplicativo trata os dois casos.
2. **Vercel:** importe o repositório e defina `NEXT_PUBLIC_SUPABASE_URL` e `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (veja `.env.example`). Escolha a região mais próxima do banco.
3. **Primeiro administrador da HUB:** crie o usuário no painel do Supabase (Authentication → Add user), com um e-mail só para isso. Depois, no editor SQL:

   ```sql
   insert into public.profiles (id, full_name, phone, role)
   select id, 'Nome do responsável', '98900000000', 'hub_admin' from auth.users where email = 'email@da-hub.com.br';
   ```

## O que falta antes de operar com clientes reais

- **Revisão jurídica do contrato.** A versão publicada é a minuta 1.0, com `[CNPJ]`, `[endereço]`, `[PERCENTUAL]` e `[PRAZO]` por preencher. Ao fechar o texto, publique-o como nova versão. As linhas de assinatura em papel da minuta foram omitidas porque o aceite é eletrônico.
- **Pagamento real.** Hoje o pagamento é simulado (`pay_request`) e o repasse é registrado manualmente pela HUB. Falta integrar um provedor com Pix e divisão automática; o ponto de integração está marcado na função.
- **Termos de uso e política de privacidade do cliente**, incluindo garantia do serviço, reembolso e canal de reclamação (cláusulas 8.e e 13.3).
- **Verificação documental.** O credenciamento coleta os dados, mas ainda não recebe arquivos (documento, certificados, fotos dos equipamentos).
- **Avisos em tempo real.** As telas se atualizam sozinhas a cada poucos segundos enquanto abertas; ainda não há notificação push para o prestador com o app fechado.
- **Mapa.** O app calcula distância e abre a rota no aplicativo de mapas do aparelho, mas não desenha mapa próprio.
- **Preços e comissão.** Os preços do catálogo, a comissão de 20% e o repasse em 7 dias são valores de partida para o piloto, não uma recomendação comercial.
- **Limite de tentativas de login e recuperação de senha** pelo aplicativo.
