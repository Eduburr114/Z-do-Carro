import type { Metadata } from 'next'
import { notFound } from 'next/navigation'
import { RatingBadge, SectionTitle } from '@/components/app/bits'
import { ActionForm, CheckboxField, SelectField, SubmitButton, TextareaField } from '@/components/ui/form'
import { Badge, DefinitionList, Empty, Notice, Panel } from '@/components/ui/primitives'
import { decideProvider, resolveSuspension, suspendProvider } from '@/features/hub/actions'
import { requireStaff } from '@/lib/auth/session'
import { formatDateTime, formatDoc, formatPercent, formatPhone, providerStatus } from '@/lib/format'
import { rpc } from '@/lib/rpc'
import { DocumentList } from '@/features/documents/list'
import type { ProviderDocument, ProviderStatus, Rating, Suspension } from '@/lib/types'

export const metadata: Metadata = { title: 'Prestador' }

type Detail = {
  id: string; name: string; phone: string; status: ProviderStatus; online: boolean
  doc_type: string | null; doc_number: string | null; legal_name: string | null; city: string | null
  experience: string; radius_km: number; review_note: string | null; applied_at: string | null; decided_at: string | null
  rating: Rating; completed: number
  services: { id: string; name: string; status: 'requested' | 'approved' | 'rejected' }[]
  documents: ProviderDocument[]
  acceptances: { version: string; accepted_at: string; signer_name: string; ip: string | null; body_sha256: string; commission_percent: number; payout_days: number; current: boolean }[]
  suspensions: Suspension[]
}

export default async function ProviderDetailPage({ params }: { params: Promise<{ id: string }> }) {
  await requireStaff('admin')
  const { id } = await params
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound()
  const p = await rpc<Detail | null>('admin_provider', { p_id: id })
  if (!p) notFound()
  const open = p.suspensions.find((s) => !s.resolved_at)
  const past = p.suspensions.filter((s) => s.resolved_at)

  return (
    <>
      <div className="flex flex-wrap items-center gap-2">
        <h1 className="text-2xl font-semibold">{p.legal_name ?? p.name}</h1>
        <Badge tone={providerStatus[p.status].tone}>{providerStatus[p.status].label}</Badge>
      </div>
      <div className="mt-1"><RatingBadge rating={p.rating} /></div>

      <SectionTitle>Dados do credenciamento</SectionTitle>
      <Panel>
        <DefinitionList
          items={[
            ['Responsável', p.name],
            ['Telefone', formatPhone(p.phone)],
            [p.doc_type === 'cnpj' ? 'CNPJ' : 'CPF', formatDoc(p.doc_number)],
            ['Cidade e raio', `${p.city ?? '—'} · ${p.radius_km} km`],
            ['Enviado em', formatDateTime(p.applied_at)],
            ['Atendimentos concluídos', p.completed],
          ]}
        />
        {p.experience ? <p className="border-t border-border px-4 py-3 text-sm whitespace-pre-wrap sm:px-5">{p.experience}</p> : null}
      </Panel>

      <SectionTitle>Documentos enviados</SectionTitle>
      <Panel><DocumentList documents={p.documents} /></Panel>

      {p.status === 'pending' || p.status === 'approved' ? (
        <>
          <SectionTitle>{p.status === 'pending' ? 'Decisão do credenciamento' : 'Rever habilitações'}</SectionTitle>
          <Panel className="px-4 py-4 sm:px-5">
            <ActionForm action={decideProvider} successMessage="Decisão registrada." resetOnSuccess={false}>
              <input type="hidden" name="id" value={p.id} />
              <fieldset className="space-y-3">
                <legend className="mb-2 block text-sm font-semibold">Serviços habilitados após a verificação técnica</legend>
                {p.services.map((service) => (
                  <CheckboxField key={service.id} name="service_ids[]" value={service.id} label={service.name} defaultChecked={service.status !== 'rejected'} />
                ))}
              </fieldset>
              <TextareaField label="Observação ao prestador" name="note" hint="Obrigatória ao recusar: explique o que falta." defaultValue={p.review_note ?? ''} />
              <SelectField label="Decisão" name="decision" defaultValue="approve">
                <option value="approve">Aprovar os serviços marcados</option>
                <option value="reject">Recusar o credenciamento</option>
              </SelectField>
              <SubmitButton className="w-full sm:w-auto">Registrar decisão</SubmitButton>
            </ActionForm>
          </Panel>
        </>
      ) : null}

      {open ? (
        <>
          <SectionTitle>Suspensão em vigor</SectionTitle>
          <Panel className="space-y-3 px-4 py-4 sm:px-5">
            <p className="text-sm text-muted-foreground">Desde {formatDateTime(open.created_at)}{open.precautionary ? ' · medida cautelar' : ''}</p>
            <Notice tone="danger" title="Motivo">{open.reason}</Notice>
            {open.contested_at ? (
              <Notice tone="warning" title={`Contestação do prestador em ${formatDateTime(open.contested_at)}`}>{open.contest_text}</Notice>
            ) : (
              <p className="text-sm text-muted-foreground">O prestador ainda não contestou.</p>
            )}
            <ActionForm action={resolveSuspension} successMessage="Revisão registrada.">
              <input type="hidden" name="id" value={open.id} />
              <TextareaField label="Fundamentação da revisão" name="note" />
              <SelectField label="Decisão" name="decision" defaultValue="lift">
                <option value="lift">Encerrar a suspensão e reativar</option>
                <option value="uphold">Manter a suspensão</option>
              </SelectField>
              <SubmitButton className="w-full sm:w-auto">Registrar revisão</SubmitButton>
            </ActionForm>
          </Panel>
        </>
      ) : p.status === 'approved' ? (
        <>
          <SectionTitle>Suspender credenciamento</SectionTitle>
          <Panel className="px-4 py-4 sm:px-5">
            <p className="mb-3 text-sm text-muted-foreground">
              Só por motivo objetivo: fraude comprovada, perda de habilitação, equipamento inseguro ou descumprimento grave. Recusar pedidos ou ficar indisponível não é motivo. O prestador vê o motivo e pode contestar.
            </p>
            <ActionForm action={suspendProvider} successMessage="Credenciamento suspenso.">
              <input type="hidden" name="id" value={p.id} />
              <TextareaField label="Motivo objetivo" name="reason" />
              <CheckboxField name="precautionary" label="Medida cautelar urgente" hint="Para prevenir dano imediato, antes de ouvir o prestador." />
              <SubmitButton variant="danger" className="w-full sm:w-auto">Suspender</SubmitButton>
            </ActionForm>
          </Panel>
        </>
      ) : null}

      <SectionTitle>Aceites do contrato</SectionTitle>
      <Panel>
        {p.acceptances.length === 0 ? (
          <Empty title="Nenhum aceite registrado" />
        ) : (
          <ul className="divide-y divide-border">
            {p.acceptances.map((a) => (
              <li key={a.version} className="px-4 py-3 text-sm sm:px-5">
                <p className="font-semibold">Versão {a.version}{a.current ? ' (vigente)' : ''} · {formatDateTime(a.accepted_at)}</p>
                <p className="text-muted-foreground">
                  {a.signer_name} · IP {a.ip ?? '—'} · comissão {formatPercent(a.commission_percent)} · repasse em até {a.payout_days} dias
                </p>
                <p className="text-xs break-all text-muted-foreground">SHA-256 {a.body_sha256}</p>
              </li>
            ))}
          </ul>
        )}
      </Panel>

      {past.length > 0 ? (
        <>
          <SectionTitle>Suspensões anteriores</SectionTitle>
          <Panel>
            <ul className="divide-y divide-border">
              {past.map((s) => (
                <li key={s.id} className="px-4 py-3 text-sm sm:px-5">
                  <p className="font-semibold">{formatDateTime(s.created_at)} · {s.resolution === 'lifted' ? 'encerrada' : 'mantida'} em {formatDateTime(s.resolved_at)}</p>
                  <p>{s.reason}</p>
                  {s.contest_text ? <p className="text-muted-foreground">Contestação: {s.contest_text}</p> : null}
                  <p className="text-muted-foreground">Revisão: {s.resolution_note}</p>
                </li>
              ))}
            </ul>
          </Panel>
        </>
      ) : null}
    </>
  )
}
