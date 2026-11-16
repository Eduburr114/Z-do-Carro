import { ShieldCheck } from 'lucide-react'
import { CopyButton } from '@/components/app/copy-button'
import { ActionForm, Field, SubmitButton } from '@/components/ui/form'
import { Notice, Panel } from '@/components/ui/primitives'
import { claimPayment, savePaymentTaxId, startPayment } from '@/features/customer/actions'
import { requestTime } from '@/lib/clock'
import { formatDateTime, formatMoney } from '@/lib/format'
import type { CustomerPayment, PaymentInfo, ServiceRequest } from '@/lib/types'

/**
 * Pagamento por Pix de um pedido (ou de um adicional aprovado). A tela só
 * mostra a cobrança; quem confirma é o provedor, por webhook, e a página se
 * atualiza sozinha (AutoRefresh na página do pedido).
 */
export function PaymentPanel({ request, info, extra }: {
  request: ServiceRequest
  info: PaymentInfo
  extra?: ServiceRequest['extras'][number]
}) {
  const payments = request.payments ?? []
  const amount = extra ? extra.price : request.total - request.extras_total
  const mine = (p: CustomerPayment) => (extra ? p.extra_id === extra.id : p.kind === 'service')
  const open = payments.filter(mine).find((p) => p.status === 'creating' || p.status === 'pending')
  const expired = open?.pix_expires_at ? new Date(open.pix_expires_at).getTime() < requestTime() : false
  const title = extra ? `Pague o adicional: ${extra.description}` : `Pague ${formatMoney(amount)} por Pix`

  return (
    <Panel className="mt-5 border-2 border-brand px-4 py-4">
      <p className="text-lg font-semibold">{title}</p>
      {extra ? <p className="font-display text-2xl font-semibold tabular-nums">{formatMoney(extra.price)}</p> : null}

      {info.mode === 'asaas' && !info.has_tax_id ? (
        <ActionForm action={savePaymentTaxId} successMessage="CPF salvo." className="mt-3">
          <Field label="CPF ou CNPJ do pagador" name="tax_id" inputMode="numeric" autoComplete="off" placeholder="000.000.000-00" required />
          <p className="text-sm text-muted-foreground">
            Exigido pelo emissor da cobrança Pix. Guardamos só para emitir as suas cobranças, separado do seu perfil.
          </p>
          <SubmitButton className="w-full">Continuar</SubmitButton>
        </ActionForm>
      ) : !open || expired ? (
        <ActionForm action={startPayment} className="mt-3">
          <input type="hidden" name="id" value={request.id} />
          <input type="hidden" name="extra_id" value={extra?.id ?? ''} />
          {expired ? <Notice tone="warning" className="mb-3">O código anterior venceu. Gere um novo.</Notice> : null}
          <SubmitButton size="lg" className="w-full">Gerar Pix de {formatMoney(amount)}</SubmitButton>
        </ActionForm>
      ) : open.status === 'creating' ? (
        <Notice tone="info" className="mt-3">Gerando a cobrança Pix. Esta tela se atualiza sozinha.</Notice>
      ) : open.method === 'pix_manual' ? (
        <>
          <dl className="mt-3 space-y-2 rounded-(--radius-control) bg-surface-2 px-3 py-3 text-sm">
            <div>
              <dt className="text-muted-foreground">Chave Pix</dt>
              <dd className="flex items-center justify-between gap-2 font-semibold break-all">
                {info.pix_key}
                <CopyButton text={info.pix_key ?? ''} />
              </dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Favorecido</dt>
              <dd className="font-semibold">{info.pix_holder}</dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Valor · identificação</dt>
              <dd className="font-semibold tabular-nums">{formatMoney(open.amount)} · pedido nº {request.number}</dd>
            </div>
          </dl>
          {open.claimed ? (
            <Notice tone="info" title="Aguardando a conferência da HUB" className="mt-3">
              A equipe financeira confere o Pix no extrato. Só depois disso o pedido segue.
            </Notice>
          ) : (
            <ActionForm action={claimPayment} successMessage="Aviso enviado à HUB." className="mt-3">
              <input type="hidden" name="id" value={request.id} />
              <SubmitButton size="lg" className="w-full">Já fiz o Pix</SubmitButton>
            </ActionForm>
          )}
        </>
      ) : (
        <>
          {open.pix_qr_image ? (
            <div className="mt-3 flex justify-center rounded-(--radius-control) bg-white p-3">
              {/* eslint-disable-next-line @next/next/no-img-element -- imagem em base64 gerada pelo provedor */}
              <img src={`data:image/png;base64,${open.pix_qr_image}`} alt="QR Code do Pix" width={220} height={220} className="size-55" />
            </div>
          ) : null}
          {open.pix_payload ? (
            <div className="mt-3">
              <p className="text-sm font-semibold">Pix copia e cola</p>
              <div className="mt-1 flex items-center gap-2">
                <code className="block min-w-0 flex-1 truncate rounded-(--radius-control) bg-surface-2 px-3 py-2 text-xs">{open.pix_payload}</code>
                <CopyButton text={open.pix_payload} />
              </div>
            </div>
          ) : (
            <Notice tone="info" className="mt-3">Carregando o código Pix…</Notice>
          )}
          <p className="mt-3 flex items-start gap-2 text-sm text-muted-foreground">
            <ShieldCheck className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
            <span>
              A confirmação chega sozinha do banco em poucos segundos; não precisa enviar comprovante.
              {open.pix_expires_at ? ` Código válido até ${formatDateTime(open.pix_expires_at)}.` : ''}
            </span>
          </p>
        </>
      )}
      {!extra && request.payment_due_at ? (
        <p className="mt-3 text-xs text-muted-foreground">
          Sem pagamento até {formatDateTime(request.payment_due_at)}, o pedido é encerrado. O valor fica retido e só vai para o prestador depois
          que você confirmar o serviço; cancelando antes do início, você recebe tudo de volta.
        </p>
      ) : null}
    </Panel>
  )
}
