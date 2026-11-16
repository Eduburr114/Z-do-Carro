import type { Metadata } from 'next'
import Link from 'next/link'
import { LegalDocument } from '@/components/app/legal'

export const metadata: Metadata = { title: 'Termos de Uso' }

export default function TermsPage() {
  return (
    <LegalDocument title="Termos de Uso do Zé do Carro">
      <section>
        <h2>1. Quem somos</h2>
        <p>
          O Zé do Carro é uma plataforma da HUB Tecnologia e Serviços Automotivos Ltda., inscrita no CNPJ sob nº [CNPJ], com sede em [endereço] (“HUB”). A plataforma aproxima clientes que precisam de serviços automotivos móveis de prestadores credenciados que os executam.
        </p>
      </section>
      <section>
        <h2>2. Como o serviço funciona</h2>
        <ul>
          <li>O cliente escolhe o serviço, informa o veículo e o local, e vê o preço antes de confirmar o pedido.</li>
          <li>O pedido é oferecido a prestadores credenciados e habilitados para aquele serviço. O atendimento depende de haver um prestador disponível na região, o que a HUB não garante em todos os horários e locais.</li>
          <li>O serviço é executado pelo prestador que aceitou o pedido, profissional autônomo ou empresa independente, credenciado após análise técnica e documental da HUB.</li>
        </ul>
      </section>
      <section>
        <h2>3. Preço, serviços adicionais e pagamento</h2>
        <ul>
          <li>O preço exibido no pedido é o valor do serviço contratado. Peças e insumos só estão incluídos quando a descrição do serviço disser isso.</li>
          <li>Qualquer serviço adicional depende de orçamento enviado pelo aplicativo e de aprovação expressa do cliente, também pelo aplicativo. Sem aprovação, o adicional não é devido.</li>
          <li>O pagamento é feito depois da conclusão do serviço, pelo meio indicado no aplicativo. A HUB retém a sua comissão e repassa o restante ao prestador.</li>
        </ul>
      </section>
      <section>
        <h2>4. Cancelamento</h2>
        <p>
          O cliente pode cancelar o pedido pelo aplicativo, sem custo, até o início do serviço. Depois de iniciado, o cancelamento deve ser tratado com o suporte. O direito de arrependimento e as demais regras do Código de Defesa do Consumidor permanecem aplicáveis.
        </p>
      </section>
      <section>
        <h2>5. Garantia e reclamações</h2>
        <ul>
          <li>Os serviços contam com a garantia legal prevista no Código de Defesa do Consumidor.</li>
          <li>Reclamações, pedidos de reembolso e acionamento de garantia devem ser feitos pelo canal [e-mail ou telefone de atendimento], informando o número do pedido. A HUB responde em até [prazo] dias úteis.</li>
          <li>A divisão de responsabilidades entre a HUB e o prestador não reduz os direitos do consumidor previstos em lei.</li>
        </ul>
      </section>
      <section>
        <h2>6. Deveres de quem usa a plataforma</h2>
        <ul>
          <li>Informar dados verdadeiros e manter o cadastro atualizado.</li>
          <li>Garantir condições seguras de acesso ao veículo no local informado.</li>
          <li>Não combinar pagamentos fora do aplicativo para serviços solicitados por ele.</li>
          <li>Tratar as pessoas com respeito. Ofensas, ameaças ou fraude podem levar ao bloqueio da conta.</li>
        </ul>
      </section>
      <section>
        <h2>7. Avaliações</h2>
        <p>Depois do pagamento, o cliente pode avaliar o atendimento. As avaliações são usadas no controle de qualidade da rede e podem ser exibidas de forma resumida a outros clientes.</p>
      </section>
      <section>
        <h2>8. Dados pessoais</h2>
        <p>
          O tratamento de dados pessoais segue a <Link href="/privacidade" className="font-semibold text-primary underline-offset-4 hover:underline">Política de Privacidade</Link>, que faz parte destes termos.
        </p>
      </section>
      <section>
        <h2>9. Alterações e foro</h2>
        <p>
          Mudanças relevantes nestes termos serão comunicadas pelo aplicativo antes de valerem. Fica eleito o foro do domicílio do consumidor para resolver questões relativas a estes termos.
        </p>
      </section>
    </LegalDocument>
  )
}
