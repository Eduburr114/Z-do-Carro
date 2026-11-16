-- =============================================================================
-- Zé do Carro — 03 Dados iniciais
-- Regras da plataforma, catálogo de serviços (cláusula 1.2 do contrato) e a
-- versão 1.0 do contrato de credenciamento.
--
-- ATENÇÃO: preços, comissão e prazo de repasse abaixo são VALORES DE PARTIDA
-- para o piloto, ajustáveis no painel da HUB. O contrato é a minuta 1.0, ainda
-- com campos a preencher ([CNPJ], [PERCENTUAL], [PRAZO]) e pendente de revisão
-- jurídica. O texto abaixo é gerado de supabase/contracts/credenciamento-v1.0.txt.
-- =============================================================================

insert into public.settings (id) values (true);

insert into public.services (code, name, description, base_price, est_minutes, sort) values
  ('troca_pneu', 'Troca de pneu', 'Troca do pneu furado pelo estepe ou por pneu novo fornecido pelo cliente.', 80.00, 30, 10),
  ('troca_oleo', 'Troca de óleo', 'Mão de obra da troca de óleo e filtro, com descarte correto do óleo usado. Óleo e filtro à parte.', 120.00, 40, 20),
  ('balanceamento', 'Balanceamento', 'Balanceamento das quatro rodas com equipamento móvel.', 100.00, 50, 30),
  ('alinhamento', 'Alinhamento', 'Alinhamento da direção com equipamento móvel.', 140.00, 60, 40),
  ('higienizacao_basica', 'Higienização básica', 'Limpeza e higienização interna básica do veículo.', 150.00, 90, 50);

insert into public.contract_versions (version, title, body, body_sha256, is_current)
select '1.0', 'Contrato de Credenciamento e Intermediação de Serviços Automotivos', c.body,
       encode(extensions.digest(c.body, 'sha256'), 'hex'), true
from (select $contrato$CONTRATO DE CREDENCIAMENTO E INTERMEDIAÇÃO DE SERVIÇOS AUTOMOTIVOS

HUB Tecnologia e Serviços Automotivos Ltda.

CONTRATANTE/PLATAFORMA: HUB Tecnologia e Serviços Automotivos Ltda., pessoa jurídica de direito privado, inscrita no CNPJ sob nº [CNPJ], com sede em [endereço].

PRESTADOR CREDENCIADO: [Nome ou razão social], inscrito no CPF/CNPJ sob nº [número], com endereço em [endereço].

As partes celebram o presente instrumento de credenciamento e intermediação tecnológica, nos termos das cláusulas seguintes.

CLÁUSULA 1 — DO OBJETO

1.1. O presente contrato estabelece as condições para o credenciamento do PRESTADOR em plataforma digital destinada à intermediação de serviços automotivos móveis.

1.2. Os serviços poderão compreender troca de pneus, alinhamento, balanceamento, troca de óleo, higienização automotiva básica e outros procedimentos tecnicamente habilitados e legalmente permitidos.

1.3. A inclusão de novos serviços dependerá da verificação dos requisitos técnicos, ambientais e regulatórios aplicáveis.

CLÁUSULA 2 — DA NATUREZA DA RELAÇÃO

2.1. O PRESTADOR atuará como profissional autônomo ou empresa independente, sem exclusividade, subordinação jurídica ou obrigação de disponibilidade permanente perante a HUB.

2.2. O presente instrumento possui natureza civil e comercial, não constituindo, por si só, relação de emprego, sociedade, representação comercial ou mandato geral entre as partes.

2.3. As disposições deste contrato deverão corresponder à efetiva autonomia profissional exercida na prática, observada a legislação aplicável.

CLÁUSULA 3 — DA AUTONOMIA PROFISSIONAL

3.1. O PRESTADOR terá plena liberdade para estabelecer os dias, horários e regiões em que deseja disponibilizar seus serviços.

3.2. A conexão à plataforma ocorrerá por iniciativa do PRESTADOR, sem obrigação de jornada mínima, escala, plantão ou quantidade mínima de atendimentos.

3.3. O PRESTADOR poderá aceitar ou recusar solicitações, sem penalidades ou redução de classificação decorrentes exclusivamente da recusa.

3.4. Será permitida a prestação de serviços para empresas concorrentes, oficinas, clientes particulares e outras plataformas.

3.5. O PRESTADOR poderá interromper sua disponibilidade a qualquer momento, respeitadas as obrigações assumidas nos atendimentos previamente aceitos.

CLÁUSULA 4 — DO CREDENCIAMENTO E DA QUALIFICAÇÃO

4.1. O acesso às solicitações dependerá de aprovação em procedimento de credenciamento técnico e documental.

4.2. A HUB poderá aplicar provas de conhecimentos, avaliações práticas e verificações de certificações relativas aos serviços pretendidos.

4.3. A aprovação atestará o cumprimento dos requisitos mínimos de credenciamento e não constituirá promessa de contratação, remuneração ou quantidade de serviços.

4.4. A reavaliação técnica poderá ocorrer mediante critérios objetivos e previamente informados, especialmente em caso de atualização tecnológica ou ocorrência relacionada à segurança.

CLÁUSULA 5 — DOS EQUIPAMENTOS E PRODUTOS

5.1. O PRESTADOR utilizará ferramentas, equipamentos e produtos compatíveis com as especificações técnicas e de segurança divulgadas pela HUB.

5.2. Os equipamentos e produtos poderão ser adquiridos de fornecedores livremente escolhidos pelo PRESTADOR, desde que atendam aos requisitos objetivos de compatibilidade e qualidade.

5.3. A HUB poderá oferecer kits padronizados para aquisição facultativa, sem exigir compra exclusiva de sua própria rede comercial.

5.4. A manutenção, conservação e regularidade dos equipamentos próprios serão de responsabilidade do PRESTADOR, observadas as regras legais aplicáveis.

CLÁUSULA 6 — DO ACEITE E DA EXECUÇÃO DOS SERVIÇOS

6.1. As solicitações serão apresentadas no aplicativo, contendo, quando disponível, localização, natureza do atendimento, estimativa de preço, remuneração líquida e condições relevantes.

6.2. O PRESTADOR decidirá livremente sobre o aceite.

6.3. Após o aceite, comprometer-se-á a executar o serviço contratado com diligência técnica, segurança e observância das condições informadas ao cliente.

6.4. O PRESTADOR manterá autonomia sobre os procedimentos técnicos adequados, respeitadas as normas legais, as instruções dos fabricantes e as especificações de segurança.

6.5. Serviços adicionais dependerão de orçamento e autorização do cliente, registrados na plataforma.

6.6. A eventual substituição do profissional executor somente poderá ocorrer por outro profissional devidamente credenciado e habilitado, mediante comunicação e concordância do cliente quando necessária.

CLÁUSULA 7 — DA REMUNERAÇÃO E DAS COMISSÕES

7.1. A remuneração decorrerá dos serviços efetivamente contratados e executados, não havendo salário fixo ou garantia de faturamento mínimo.

7.2. A HUB receberá uma comissão de [PERCENTUAL]% sobre a base de cálculo definida no Anexo Financeiro.

7.3. Antes de aceitar cada solicitação, o PRESTADOR terá acesso à estimativa de sua remuneração líquida e aos descontos aplicáveis.

7.4. Os pagamentos serão processados por instituição ou prestador de serviços de pagamento integrado à plataforma, observadas as regras financeiras e regulatórias aplicáveis.

7.5. Os repasses ocorrerão em até [PRAZO] após a confirmação das condições para liberação do pagamento, ressalvadas contestações, estornos e retenções justificadas e legalmente admitidas.

7.6. Tributos e obrigações fiscais serão tratados conforme a natureza jurídica da operação e a condição tributária de cada parte.

CLÁUSULA 8 — DAS RESPONSABILIDADES DA HUB

Compete à HUB:

a) Disponibilizar e administrar a plataforma tecnológica.

b) Realizar o credenciamento e a verificação documental dos profissionais.

c) Estabelecer requisitos objetivos de qualidade e segurança.

d) Intermediar solicitações, pagamentos e canais de atendimento.

e) Oferecer mecanismos de reclamação, avaliação e solução de conflitos.

f) Cumprir as obrigações legais que lhe sejam atribuídas, inclusive perante consumidores e titulares de dados.

CLÁUSULA 9 — DAS RESPONSABILIDADES DO PRESTADOR

Compete ao PRESTADOR:

a) Manter válidas as habilitações e autorizações exigíveis.

b) Utilizar produtos e equipamentos adequados.

c) Cumprir os serviços que livremente aceitar, ressalvadas situações justificadas.

d) Observar exigências de segurança, proteção ambiental e destinação de resíduos.

e) Registrar corretamente a realização do atendimento.

f) Preservar os bens e a privacidade dos clientes.

g) Responder por sua conduta e pelas falhas que lhe sejam legalmente imputáveis, sem prejuízo da responsabilidade de outros integrantes da cadeia de fornecimento.

CLÁUSULA 10 — DO CONTROLE DE QUALIDADE

10.1. A HUB poderá verificar a conformidade dos serviços prestados mediante avaliações dos clientes, documentos, registros técnicos e auditorias proporcionais.

10.2. O controle de qualidade terá por finalidade a segurança, a regularidade dos serviços e a proteção dos consumidores, não constituindo autorização para impor jornadas ou exercer direção cotidiana sobre a atividade do PRESTADOR.

10.3. A recusa de chamados ou a ausência de conexão à plataforma não será utilizada, isoladamente, como fundamento de punição.

CLÁUSULA 11 — DA SUSPENSÃO DO CREDENCIAMENTO

11.1. O credenciamento poderá ser suspenso por motivos objetivos, como fraude comprovada, perda de habilitação, utilização de equipamentos inseguros ou descumprimento grave das obrigações contratuais.

11.2. A HUB comunicará os motivos da medida e oferecerá mecanismo de contestação e revisão, ressalvadas medidas cautelares urgentes para prevenção de danos.

11.3. Eventuais prejuízos e ressarcimentos serão apurados segundo a responsabilidade efetiva das partes, vedados descontos arbitrários.

CLÁUSULA 12 — DA PROTEÇÃO DE DADOS

12.1. As partes observarão a Lei Geral de Proteção de Dados Pessoais — LGPD.

12.2. O PRESTADOR acessará apenas os dados necessários à realização dos serviços aceitos.

12.3. Ficam vedados o compartilhamento não autorizado, a comercialização de dados e o uso de informações dos clientes para finalidades incompatíveis com o atendimento.

12.4. O tratamento de dados de localização deverá ser limitado às finalidades legítimas de disponibilização, execução e segurança dos serviços, com transparência ao titular.

CLÁUSULA 13 — DA RESPONSABILIDADE PERANTE TERCEIROS

13.1. Cada parte responderá por seus atos e omissões na extensão de sua responsabilidade legal.

13.2. A distribuição contratual das responsabilidades não afastará direitos dos consumidores, garantias legais ou hipóteses de responsabilidade solidária previstas na legislação.

13.3. Os procedimentos de reclamação, reembolso, garantia e ressarcimento observarão a legislação aplicável e os termos apresentados ao consumidor.

CLÁUSULA 14 — DA VIGÊNCIA E DO ENCERRAMENTO

14.1. O presente contrato terá vigência por prazo indeterminado.

14.2. Qualquer parte poderá solicitar o encerramento do credenciamento, respeitados os atendimentos já assumidos, os valores pendentes e as obrigações legais sobreviventes.

14.3. A rescisão não prejudicará o pagamento de remunerações devidas por serviços efetivamente prestados.

CLÁUSULA 15 — DAS DISPOSIÇÕES FINAIS

15.1. O contrato poderá ser formalizado eletronicamente, mediante mecanismo que assegure a identificação do signatário, a integridade do documento e o registro do aceite.

15.2. Alterações relevantes serão comunicadas previamente, sendo apresentado novo termo para aceitação quando necessário.

15.3. Os litígios serão submetidos ao juízo legalmente competente, respeitadas as regras de competência obrigatória.

15.4. Integram este instrumento os anexos referentes aos serviços autorizados, requisitos dos equipamentos, política de remuneração e procedimentos de segurança.

Local e data: São Luís/MA, [DATA].

Versão do contrato: 1.0 — minuta para revisão jurídica.$contrato$::text as body) c;
