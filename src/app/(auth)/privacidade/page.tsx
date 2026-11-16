import type { Metadata } from 'next'
import { LegalDocument } from '@/components/app/legal'

export const metadata: Metadata = { title: 'Política de Privacidade' }

export default function PrivacyPage() {
  return (
    <LegalDocument title="Política de Privacidade do Zé do Carro">
      <section>
        <h2>1. Controladora dos dados</h2>
        <p>
          A HUB Tecnologia e Serviços Automotivos Ltda., CNPJ [CNPJ], é a controladora dos dados pessoais tratados no Zé do Carro. Encarregado pelo tratamento de dados: [nome e e-mail do encarregado].
        </p>
      </section>
      <section>
        <h2>2. Quais dados tratamos e para quê</h2>
        <ul>
          <li><strong>Cadastro</strong> (nome, e-mail, telefone): criar a conta, identificar as partes do atendimento e permitir o contato entre cliente e prestador durante o serviço.</li>
          <li><strong>Veículo</strong> (placa, marca, modelo e ano): informar ao prestador qual veículo será atendido.</li>
          <li><strong>Endereço e localização do atendimento</strong>: encontrar prestadores na região e levar o prestador até o veículo. A localização do aparelho só é lida quando você toca no botão correspondente.</li>
          <li><strong>Localização do prestador</strong>: registrada somente enquanto ele está disponível ou em atendimento, para oferecer pedidos próximos e mostrar o deslocamento ao cliente.</li>
          <li><strong>Credenciamento do prestador</strong> (CPF ou CNPJ, documentos, certificados, fotos de equipamentos, aceite do contrato com data, hora e endereço IP): verificar a qualificação e comprovar o aceite.</li>
          <li><strong>Pedidos, pagamentos e avaliações</strong>: executar o contrato, calcular comissões e repasses, cumprir obrigações fiscais e controlar a qualidade.</li>
        </ul>
      </section>
      <section>
        <h2>3. Bases legais</h2>
        <p>Tratamos os dados para executar o contrato com você, cumprir obrigações legais e regulatórias, exercer direitos em eventuais processos e atender ao legítimo interesse de segurança e prevenção a fraudes, nos termos da Lei nº 13.709/2018 (LGPD).</p>
      </section>
      <section>
        <h2>4. Com quem compartilhamos</h2>
        <ul>
          <li><strong>Prestador que aceitou o seu pedido</strong>: recebe nome, telefone, placa e endereço do atendimento. Antes do aceite, os prestadores veem apenas o serviço, o modelo do veículo e o local.</li>
          <li><strong>Cliente</strong>: vê o nome, o telefone, a nota e a distância do prestador que aceitou o pedido.</li>
          <li><strong>Fornecedores de tecnologia</strong> que hospedam o aplicativo e o banco de dados, e o provedor de pagamentos, sob contrato e apenas para essas finalidades.</li>
          <li><strong>Autoridades</strong>, quando houver obrigação legal ou ordem judicial.</li>
        </ul>
        <p>Não vendemos dados pessoais. O prestador é proibido de usar os dados dos clientes para fins diferentes do atendimento.</p>
      </section>
      <section>
        <h2>5. Por quanto tempo guardamos</h2>
        <p>Guardamos os dados enquanto a conta estiver ativa e, depois, pelos prazos necessários para cumprir obrigações legais e resguardar direitos: [prazos de retenção a definir com o jurídico]. Registros de acesso são mantidos pelo prazo do Marco Civil da Internet.</p>
      </section>
      <section>
        <h2>6. Seus direitos</h2>
        <p>Você pode pedir confirmação do tratamento, acesso, correção, portabilidade, anonimização ou eliminação dos seus dados, e informações sobre compartilhamento, pelo canal [e-mail do encarregado]. Também pode apresentar reclamação à Autoridade Nacional de Proteção de Dados (ANPD).</p>
      </section>
      <section>
        <h2>7. Segurança</h2>
        <p>O acesso aos dados é controlado no banco de dados por perfil de usuário, a comunicação é criptografada e as senhas não são armazenadas em texto. Nenhum sistema é totalmente imune a incidentes; se ocorrer um que possa causar risco relevante, comunicaremos os titulares afetados e a ANPD.</p>
      </section>
      <section>
        <h2>8. Avisos no aparelho</h2>
        <p>Se você ativar os avisos, guardamos o identificador do seu navegador para enviar notificações sobre os seus pedidos. Você pode desativar a qualquer momento na tela Conta.</p>
      </section>
    </LegalDocument>
  )
}
