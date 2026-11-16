import type { Metadata } from 'next'
import { Row, SectionTitle } from '@/components/app/bits'
import { ActionForm, CheckboxField, SubmitButton } from '@/components/ui/form'
import { Notice, Panel } from '@/components/ui/primitives'
import { acceptContract, closeCredentialing } from '@/features/provider/actions'
import { requireRole } from '@/lib/auth/session'
import { formatDateTime, formatPercent } from '@/lib/format'
import { rpc } from '@/lib/rpc'
import type { Contract, ProviderHome } from '@/lib/types'

export const metadata: Metadata = { title: 'Contrato' }

export default async function ContractPage() {
  await requireRole('provider')
  const [contract, home] = await Promise.all([rpc<Contract | null>('current_contract'), rpc<ProviderHome>('provider_home')])
  if (!contract) return <Notice tone="warning">Nenhum contrato publicado no momento.</Notice>
  const canAccept = ['pending', 'approved', 'suspended'].includes(home.status)
  const terms = contract.acceptance ?? contract
  return (
    <>
      <p className="text-sm text-muted-foreground">Versão {contract.version}</p>
      <h1 className="text-2xl font-semibold text-balance">{contract.title}</h1>

      {contract.acceptance ? (
        <Notice tone="success" title="Contrato aceito" className="mt-4">
          Aceito eletronicamente por {contract.acceptance.signer_name} em {formatDateTime(contract.acceptance.accepted_at)}.
        </Notice>
      ) : null}

      <SectionTitle>Anexo financeiro</SectionTitle>
      <Panel className="px-4 py-3">
        <Row label="Comissão da HUB sobre o total do serviço (cláusula 7.2)" value={formatPercent(terms.commission_percent)} />
        <Row label="Prazo do repasse após o pagamento (cláusula 7.5)" value={`até ${terms.payout_days} dias`} />
        <p className="mt-1 text-sm text-muted-foreground">
          {contract.acceptance ? 'Condições registradas no seu aceite.' : 'Estas condições ficam registradas junto com o seu aceite.'} Antes de aceitar cada pedido você vê o valor líquido.
        </p>
      </Panel>

      <SectionTitle>Texto do contrato</SectionTitle>
      <Panel className="max-h-[60dvh] overflow-y-auto px-4 py-4" tabIndex={0} role="region" aria-label="Texto do contrato">
        <div className="text-sm leading-relaxed whitespace-pre-wrap">{contract.body}</div>
      </Panel>
      <p className="mt-2 text-xs break-all text-muted-foreground">Impressão digital do texto (SHA-256): {contract.body_sha256}</p>

      {!contract.acceptance ? (
        canAccept ? (
          <ActionForm action={acceptContract} successMessage="Contrato aceito." className="mt-5" resetOnSuccess={false}>
            <input type="hidden" name="version_id" value={contract.id} />
            <CheckboxField
              name="agree"
              label="Li e aceito o contrato de credenciamento e o anexo financeiro"
              hint="O aceite registra seu nome, documento, data, hora, endereço IP e a impressão digital do texto."
            />
            <SubmitButton size="lg" className="w-full">Aceitar contrato</SubmitButton>
          </ActionForm>
        ) : (
          <Notice tone="info" className="mt-5">Envie primeiro os dados do credenciamento para poder aceitar o contrato.</Notice>
        )
      ) : null}

      {['pending', 'approved'].includes(home.status) ? (
        <>
          <SectionTitle>Encerrar credenciamento</SectionTitle>
          <p className="mb-3 text-sm text-muted-foreground">
            Você pode encerrar quando quiser. Valores de serviços já prestados continuam sendo repassados normalmente.
          </p>
          <ActionForm action={closeCredentialing} successMessage="Credenciamento encerrado.">
            <CheckboxField name="confirm" label="Quero encerrar meu credenciamento" />
            <SubmitButton variant="outline" className="w-full text-danger">Encerrar credenciamento</SubmitButton>
          </ActionForm>
        </>
      ) : null}
    </>
  )
}
