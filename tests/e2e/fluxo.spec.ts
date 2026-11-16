import { expect, test, type Browser, type Page } from '@playwright/test'

/**
 * O caminho completo, com as três áreas abertas ao mesmo tempo: cadastro do
 * cliente, pedido, aceite do prestador, adicional aprovado, pagamento por Pix
 * confirmado pela HUB, avaliação e repasse; credenciamento com documento,
 * aceite do contrato, suspensão com contestação; recuperação de senha.
 */
const SENHA = 'demonstracao-local-2026'
const PNG_1PX = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64')

async function abrir(browser: Browser, desktop = false): Promise<Page> {
  const context = await browser.newContext({
    ...(desktop ? { viewport: { width: 1280, height: 900 }, isMobile: false, hasTouch: false } : {}),
    geolocation: { latitude: -2.5, longitude: -44.28 },
    permissions: ['geolocation'],
  })
  const page = await context.newPage()
  page.on('pageerror', (error) => {
    throw error
  })
  return page
}

async function entrar(page: Page, email: string, senha = SENHA) {
  await page.goto('/login')
  await page.getByLabel('E-mail').fill(email)
  await page.getByLabel('Senha').fill(senha)
  await page.getByRole('button', { name: 'Entrar' }).click()
  await page.waitForURL(/\/(cliente|prestador|hub)$/)
}

test('atendimento completo com pagamento por Pix', async ({ browser }) => {
  const hub = await abrir(browser, true)
  await entrar(hub, 'hub@demo.invalid')
  await hub.getByRole('link', { name: 'Ajustes' }).click()
  await hub.getByLabel('Chave Pix da HUB').fill('financeiro@hub.invalid')
  await hub.getByLabel('Favorecido (como aparece no banco)').fill('HUB Tecnologia e Serviços Automotivos Ltda')
  await hub.getByRole('button', { name: 'Salvar recebimento' }).click()
  await expect(hub.getByText('Recebimento salvo.')).toBeVisible()

  // Cliente novo: os termos são obrigatórios e o que foi digitado não se perde no erro.
  const cliente = await abrir(browser)
  await cliente.goto('/')
  await cliente.getByRole('link', { name: 'Pedir um serviço' }).click()
  await cliente.getByLabel('Nome completo').fill('Marina Teste')
  await cliente.getByLabel('Celular com DDD').fill('(98) 98888-7777')
  await cliente.getByLabel('E-mail').fill(`marina${Date.now()}@demo.invalid`)
  await cliente.getByLabel('Senha').fill(SENHA)
  await cliente.getByRole('button', { name: 'Criar conta' }).click()
  await expect(cliente.getByText('É preciso aceitar os termos')).toBeVisible()
  await expect(cliente.getByLabel('Nome completo')).toHaveValue('Marina Teste')
  await cliente.getByLabel(/Li e aceito os Termos/).check()
  await cliente.getByRole('button', { name: 'Criar conta' }).click()
  await cliente.waitForURL(/\/cliente$/)

  await cliente.getByRole('link', { name: /Troca de pneu/ }).click()
  await cliente.getByRole('link', { name: 'Cadastrar veículo' }).click()
  await cliente.getByLabel('Placa').fill('qwe1r23')
  await cliente.getByLabel('Marca').fill('VW')
  await cliente.getByLabel('Modelo').fill('Polo')
  await cliente.getByLabel('Ano').fill('2022')
  await cliente.getByRole('button', { name: 'Salvar veículo' }).click()
  await expect(cliente.getByText('QWE1R23')).toBeVisible()
  await cliente.getByRole('link', { name: 'Início' }).click()
  await cliente.getByRole('link', { name: /Troca de pneu/ }).click()
  await cliente.getByLabel('Onde o carro está?').fill('Av. Litorânea, 500, Calhau')
  await cliente.getByRole('button', { name: 'Usar minha localização' }).click()
  await expect(cliente.getByText('Localização capturada')).toBeVisible()
  await cliente.getByRole('button', { name: 'Confirmar pedido' }).click()
  await cliente.waitForURL(/\/cliente\/pedidos\/[0-9a-f-]+$/)
  await expect(cliente.getByRole('heading', { name: 'Procurando um prestador perto de você' })).toBeVisible()
  await expect(cliente.getByRole('img', { name: /Mapa com Seu carro/ })).toBeVisible()

  // Prestador: fica disponível, vê o líquido antes de aceitar e executa.
  const ze = await abrir(browser)
  await entrar(ze, 'ze@demo.invalid')
  await ze.getByRole('button', { name: 'Ficar disponível' }).click()
  await expect(ze.getByText('Você está disponível')).toBeVisible()
  await expect(ze.getByText('R$ 64,00')).toBeVisible()
  await ze.getByRole('button', { name: 'Aceitar' }).click()
  await ze.waitForURL(/\/prestador\/pedidos\//)
  await expect(ze.getByText('Marina Teste')).toBeVisible()
  await ze.getByRole('button', { name: 'Estou a caminho' }).click()
  await ze.getByRole('button', { name: 'Cheguei, iniciar serviço' }).click()
  await ze.getByLabel('O que mais precisa ser feito?').fill('Troca da válvula')
  await ze.getByLabel('Valor ao cliente (R$)').fill('25,00')
  await ze.getByRole('button', { name: 'Enviar orçamento ao cliente' }).click()
  await expect(ze.getByText('Aguardando o cliente')).toBeVisible()
  await ze.getByRole('button', { name: 'Concluir serviço' }).click()
  await expect(ze.getByText('Há um orçamento adicional aguardando')).toBeVisible()

  // Cliente aprova o adicional (a tela se atualiza sozinha) e o aviso chega no sino.
  await expect(cliente.getByText('Orçamento adicional', { exact: true })).toBeVisible()
  await cliente.getByRole('button', { name: 'Aprovar' }).click()
  await expect(cliente.getByText('Adicional: Troca da válvula')).toBeVisible()
  await expect(ze.getByText('Aprovado', { exact: true })).toBeVisible()
  await ze.getByRole('button', { name: 'Concluir serviço' }).click()
  await expect(ze.getByText('Aguardando o pagamento do cliente')).toBeVisible()

  // Pix: o cliente informa, a HUB confirma.
  await expect(cliente.getByText('Pague R$ 105,00 por Pix')).toBeVisible()
  await expect(cliente.getByText('financeiro@hub.invalid')).toBeVisible()
  await cliente.getByRole('button', { name: 'Já paguei' }).click()
  await expect(cliente.getByText('Aguardando a confirmação da HUB')).toBeVisible()
  await hub.goto('/hub')
  await hub.getByRole('link', { name: 'Confirmar recebimentos' }).click()
  await hub.getByRole('button', { name: /Confirmar recebimento de R\$\s105,00/ }).click()
  await expect(hub.getByText('Pago', { exact: true })).toBeVisible()
  await expect(cliente.getByText('Como foi o atendimento?')).toBeVisible()
  await cliente.getByRole('button', { name: 'Enviar avaliação' }).click()
  await expect(cliente.getByText('Você avaliou este atendimento com 5★')).toBeVisible()
  await hub.getByRole('button', { name: /Registrar repasse de R\$\s84,00/ }).click()
  await expect(hub.getByText('Repassado')).toBeVisible()

  // Avisos e ganhos do prestador.
  await ze.goto('/avisos')
  await expect(ze.getByText('Repasse realizado')).toBeVisible()
  await expect(ze.getByText('Adicional aprovado')).toBeVisible()
  await ze.goto('/prestador/ganhos')
  await expect(ze.getByText('R$ 84,00').first()).toBeVisible()

  // Cada papel só entra na própria área.
  await cliente.goto('/hub')
  await cliente.waitForURL(/\/cliente$/)
  await cliente.goto('/prestador')
  await cliente.waitForURL(/\/cliente$/)
})

test('credenciamento com documento, contrato, suspensão e contestação', async ({ browser }) => {
  // Prestador novo: sem documento o credenciamento não é enviado.
  const novo = await abrir(browser)
  await novo.goto('/cadastro?tipo=prestador')
  await novo.getByLabel('Nome completo').fill('Paulo Prestador')
  await novo.getByLabel('Celular com DDD').fill('98977776666')
  await novo.getByLabel('E-mail').fill(`paulo${Date.now()}@demo.invalid`)
  await novo.getByLabel('Senha').fill(SENHA)
  await novo.getByLabel(/Li e aceito os Termos/).check()
  await novo.getByRole('button', { name: 'Criar conta' }).click()
  await novo.waitForURL(/\/prestador$/)
  await novo.getByRole('link', { name: 'Começar credenciamento' }).click()
  await novo.getByLabel('Número').fill('123.456.789-09')
  await novo.getByLabel('Troca de pneu').check()
  await novo.getByRole('button', { name: 'Enviar para análise' }).click()
  await expect(novo.getByText('Envie ao menos um documento de identificação')).toBeVisible()
  await novo.getByLabel('Escolher arquivo do documento').setInputFiles({ name: 'cnh.png', mimeType: 'image/png', buffer: PNG_1PX })
  await expect(novo.getByRole('link', { name: 'Documento de identificação' })).toBeVisible()
  await expect(novo.getByLabel('Troca de pneu')).toBeChecked() // o formulário não foi apagado
  await novo.getByRole('button', { name: 'Enviar para análise' }).click()
  await novo.waitForURL(/\/prestador$/)
  await expect(novo.getByText('Credenciamento em análise')).toBeVisible()

  // Contrato: o aceite exige a marcação.
  await novo.getByRole('link', { name: 'Ler e aceitar o contrato' }).click()
  await expect(novo.getByText('CLÁUSULA 1 — DO OBJETO')).toBeVisible()
  await novo.getByRole('button', { name: 'Aceitar contrato' }).click()
  await expect(novo.getByText('Marque que leu e aceita')).toBeVisible()
  await novo.getByLabel(/Li e aceito o contrato/).check()
  await novo.getByRole('button', { name: 'Aceitar contrato' }).click()
  await expect(novo.getByText('Contrato aceito').first()).toBeVisible()

  // HUB: abre o documento, aprova, suspende; o prestador contesta; a HUB revê.
  const hub = await abrir(browser, true)
  await entrar(hub, 'hub@demo.invalid')
  await hub.getByRole('link', { name: 'Prestadores' }).click()
  await hub.getByRole('link', { name: /Paulo Prestador/ }).click()
  const doc = await hub.request.get(await hub.getByRole('link', { name: 'Documento de identificação' }).getAttribute('href').then((href) => href!))
  expect(doc.status()).toBe(200)
  expect(doc.headers()['content-type']).toBe('image/jpeg')
  await hub.getByRole('button', { name: 'Registrar decisão' }).click()
  await expect(hub.getByText('Suspender credenciamento')).toBeVisible()
  await hub.getByLabel('Motivo objetivo').fill('Equipamento sem condição de segurança na vistoria')
  await hub.getByRole('button', { name: 'Suspender' }).click()
  await expect(hub.getByText('Suspensão em vigor')).toBeVisible()

  await novo.goto('/prestador')
  await expect(novo.getByText('Credenciamento suspenso')).toBeVisible()
  await novo.getByLabel('Contestar a suspensão').fill('O equipamento foi substituído, segue a nota fiscal de compra.')
  await novo.getByRole('button', { name: 'Enviar contestação' }).click()
  await expect(novo.getByText('Contestação enviada').first()).toBeVisible()
  await hub.reload()
  await hub.getByLabel('Fundamentação da revisão').fill('Nota fiscal conferida, equipamento regular.')
  await hub.getByRole('button', { name: 'Registrar revisão' }).click()
  await expect(hub.getByText('Suspensões anteriores')).toBeVisible()
  await novo.goto('/prestador')
  await expect(novo.getByRole('button', { name: 'Ficar disponível' })).toBeVisible()

  // Um documento alheio não abre para quem não é o dono nem a HUB.
  const outro = await abrir(browser)
  await entrar(outro, 'cliente@demo.invalid')
  expect((await outro.request.get(doc.url())).status()).toBe(404)
})

test('equipe da HUB entra com código de ativação; senha se recupera por link', async ({ browser, request }) => {
  const hub = await abrir(browser, true)
  await entrar(hub, 'hub@demo.invalid')
  await hub.getByRole('link', { name: 'Ajustes' }).click()
  await hub.getByRole('button', { name: 'Gerar código de ativação' }).click()
  const codigo = (await hub.locator('p.font-mono').innerText()).split('\n')[0].trim()
  expect(codigo).toMatch(/^[0-9A-F]{20}$/)

  const email = `equipe${Date.now()}@demo.invalid`
  const pessoa = await abrir(browser, true)
  await pessoa.goto('/cadastro?tipo=hub')
  await pessoa.getByLabel('Nome completo').fill('Nova da Equipe')
  await pessoa.getByLabel('Celular com DDD').fill('98955554444')
  await pessoa.getByLabel('E-mail').fill(email)
  await pessoa.getByLabel('Senha').fill(SENHA)
  await pessoa.getByLabel('Código de ativação').fill(codigo)
  await pessoa.getByRole('button', { name: 'Criar acesso' }).click()
  await pessoa.waitForURL(/\/hub$/)
  await expect(pessoa.getByRole('heading', { name: 'Visão geral' })).toBeVisible()

  // O mesmo código não vale de novo.
  const intruso = await abrir(browser)
  await intruso.goto('/cadastro?tipo=hub')
  await intruso.getByLabel('Nome completo').fill('Pessoa Intrusa')
  await intruso.getByLabel('Celular com DDD').fill('98911112222')
  await intruso.getByLabel('E-mail').fill(`intruso${Date.now()}@demo.invalid`)
  await intruso.getByLabel('Senha').fill(SENHA)
  await intruso.getByLabel('Código de ativação').fill(codigo)
  await intruso.getByRole('button', { name: 'Criar acesso' }).click()
  await intruso.waitForURL(/\/ativar-hub$/)

  // Recuperação de senha: o link (lido da caixa de saída do emulador) abre a troca.
  const visitante = await abrir(browser)
  await visitante.goto('/login')
  await visitante.getByRole('link', { name: 'Esqueci minha senha' }).click()
  await expect(visitante.getByRole('heading', { name: 'Esqueci minha senha' })).toBeVisible()
  await visitante.getByLabel('E-mail').fill(email)
  await visitante.getByRole('button', { name: 'Enviar link' }).click()
  await expect(visitante.getByText('Confira o seu e-mail')).toBeVisible()
  const caixa = await request.get(`http://127.0.0.1:54321/auth/v1/local/outbox?email=${encodeURIComponent(email)}`, {
    headers: { apikey: 'sb_publishable_local_somente_desenvolvimento' },
  })
  const { link } = (await caixa.json()) as { link: string }
  await visitante.goto(link.replace('http://localhost:3000', ''))
  await visitante.waitForURL(/\/nova-senha$/)
  await visitante.getByLabel('Nova senha', { exact: true }).fill('outra-senha-2026')
  await visitante.getByLabel('Repita a nova senha').fill('outra-senha-2026')
  await visitante.getByRole('button', { name: 'Salvar nova senha' }).click()
  await expect(visitante.getByText('Senha alterada')).toBeVisible()
  // O link vale uma vez, e a senha antiga deixa de funcionar.
  const denovo = await abrir(browser)
  await denovo.goto(link.replace('http://localhost:3000', ''))
  await denovo.waitForURL(/\/recuperar\?erro=link$/)
  await denovo.goto('/login')
  await denovo.getByLabel('E-mail').fill(email)
  await denovo.getByLabel('Senha').fill(SENHA)
  await denovo.getByRole('button', { name: 'Entrar' }).click()
  await expect(denovo.getByText('E-mail ou senha incorretos.')).toBeVisible()
  await entrar(denovo, email, 'outra-senha-2026')

  // Sem o link de recuperação, uma sessão comum não troca a senha.
  await denovo.goto('/nova-senha')
  await denovo.waitForURL(/\/recuperar$/)
})
