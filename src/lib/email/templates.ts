/**
 * Modelos de e-mail transacional em português. HTML em tabelas e estilos
 * inline (compatível com Gmail, Outlook e celulares), sempre com versão texto.
 * Nenhum dado sensível (CPF, chave Pix completa, valores de outras pessoas).
 */
export type EmailContent = { subject: string; html: string; text: string }
type Data = Record<string, unknown>

const escape = (value: unknown) =>
  String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string)

function layout(input: { title: string; intro: string; rows?: [string, string][]; cta?: { label: string; url: string }; note?: string }): { html: string; text: string } {
  const rows = (input.rows ?? [])
    .map(([k, v]) => `<tr><td style="padding:6px 0;color:#5b6170;font-size:14px">${escape(k)}</td><td style="padding:6px 0;text-align:right;font-weight:600;font-size:14px;color:#14161a">${escape(v)}</td></tr>`)
    .join('')
  const html = `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escape(input.title)}</title></head>
<body style="margin:0;padding:0;background:#f3f1ec;font-family:Arial,Helvetica,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f1ec"><tr><td align="center" style="padding:24px 12px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border-radius:12px;overflow:hidden">
<tr><td style="background:#14161a;padding:18px 24px;color:#f5c400;font-size:18px;font-weight:700">Zé do Carro</td></tr>
<tr><td style="padding:24px">
<h1 style="margin:0 0 12px;font-size:20px;line-height:1.3;color:#14161a">${escape(input.title)}</h1>
<p style="margin:0 0 16px;font-size:15px;line-height:1.5;color:#2b2f36">${escape(input.intro)}</p>
${rows ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-top:1px solid #e6e3dc;border-bottom:1px solid #e6e3dc;margin:0 0 20px">${rows}</table>` : ''}
${input.cta ? `<table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#f5c400;border-radius:8px"><a href="${escape(input.cta.url)}" style="display:inline-block;padding:12px 20px;font-size:15px;font-weight:700;color:#14161a;text-decoration:none">${escape(input.cta.label)}</a></td></tr></table>` : ''}
${input.note ? `<p style="margin:20px 0 0;font-size:13px;line-height:1.5;color:#5b6170">${escape(input.note)}</p>` : ''}
</td></tr>
<tr><td style="padding:16px 24px;background:#faf9f6;font-size:12px;line-height:1.5;color:#7a7f8a">Mensagem automática da HUB Tecnologia e Serviços Automotivos. Não responda com dados pessoais ou de pagamento. Seus dados são tratados conforme a nossa Política de Privacidade.</td></tr>
</table></td></tr></table></body></html>`
  const text = [
    input.title,
    '',
    input.intro,
    ...(input.rows ?? []).map(([k, v]) => `${k}: ${v}`),
    ...(input.cta ? ['', `${input.cta.label}: ${input.cta.url}`] : []),
    ...(input.note ? ['', input.note] : []),
    '',
    '— Zé do Carro · HUB Tecnologia e Serviços Automotivos',
  ].join('\n')
  return { html, text }
}

const link = (appUrl: string, path: unknown) => `${appUrl.replace(/\/$/, '')}${typeof path === 'string' && path.startsWith('/') ? path : '/'}`

export const EMAIL_TEMPLATES = [
  'pagamento_confirmado', 'servico_concluido', 'repasse_agendado', 'repasse_realizado', 'repasse_falhou',
  'estorno_realizado', 'conta_pix_alterada', 'alerta_financeiro',
] as const
export type EmailTemplate = (typeof EMAIL_TEMPLATES)[number]

export function renderEmail(template: string, data: Data, appUrl: string): EmailContent | null {
  const pedido = `Pedido nº ${escape(data.number)}`
  switch (template) {
    case 'pagamento_confirmado':
      return {
        subject: `Pagamento confirmado — ${pedido}`,
        ...layout({
          title: 'Recebemos o seu Pix',
          intro: `O pagamento de ${data.service} foi confirmado. Já estamos chamando um prestador credenciado perto de você.`,
          rows: [['Pedido', `nº ${data.number}`], ['Serviço', String(data.service)], ['Valor pago', String(data.total)]],
          cta: { label: 'Acompanhar o pedido', url: link(appUrl, data.url_customer) },
          note: 'Se o pedido for cancelado antes do início do serviço, o valor volta integralmente para a conta de origem.',
        }),
      }
    case 'servico_concluido':
      return {
        subject: `Confirme o serviço — ${pedido}`,
        ...layout({
          title: 'Serviço concluído',
          intro: `O prestador informou que terminou o serviço de ${data.service}. Confira e confirme no aplicativo, ou conte se houve algum problema.`,
          rows: [['Pedido', `nº ${data.number}`], ['Prazo para confirmar ou contestar', String(data.deadline ?? '')]],
          cta: { label: 'Confirmar ou relatar problema', url: link(appUrl, data.url_customer) },
          note: 'Sem resposta até o prazo, o serviço é considerado confirmado.',
        }),
      }
    case 'repasse_agendado':
      return {
        subject: `Repasse agendado — ${pedido}`,
        ...layout({
          title: 'Seu repasse está agendado',
          intro: `O cliente confirmou o serviço de ${data.service}. O valor líquido será transferido para a sua chave Pix cadastrada.`,
          rows: [['Pedido', `nº ${data.number}`], ['Valor líquido', String(data.provider_net)], ['Data prevista', String(data.date ?? '')]],
          cta: { label: 'Ver meus ganhos', url: link(appUrl, '/prestador/ganhos') },
        }),
      }
    case 'repasse_realizado':
      return {
        subject: `Repasse realizado — ${pedido}`,
        ...layout({
          title: 'Transferimos o seu repasse',
          intro: `O repasse do serviço de ${data.service} foi enviado por Pix para a sua conta cadastrada.`,
          rows: [['Pedido', `nº ${data.number}`], ['Valor', String(data.provider_net)]],
          cta: { label: 'Ver meus ganhos', url: link(appUrl, '/prestador/ganhos') },
        }),
      }
    case 'repasse_falhou':
      return {
        subject: `Repasse não concluído — ${pedido}`,
        ...layout({
          title: 'Não conseguimos concluir o seu repasse',
          intro: 'A transferência não foi concluída depois de algumas tentativas. Confira se a sua chave Pix está correta e ativa; a HUB também foi avisada.',
          rows: [['Pedido', `nº ${data.number}`], ['Valor', String(data.provider_net)]],
          cta: { label: 'Conferir minha conta Pix', url: link(appUrl, '/prestador/ganhos') },
        }),
      }
    case 'estorno_realizado':
      return {
        subject: `Estorno concluído — ${pedido}`,
        ...layout({
          title: 'Devolvemos o seu pagamento',
          intro: `O valor pago no pedido de ${data.service} foi estornado para a conta de origem do Pix.`,
          rows: [['Pedido', `nº ${data.number}`], ['Valor', String(data.total)]],
          cta: { label: 'Ver o pedido', url: link(appUrl, data.url_customer) },
          note: 'O prazo para o valor aparecer no extrato depende do seu banco.',
        }),
      }
    case 'conta_pix_alterada':
      return {
        subject: 'Sua conta de recebimento foi alterada',
        ...layout({
          title: 'Nova chave Pix cadastrada',
          intro: `Uma nova chave Pix (tipo ${data.key_type}) foi cadastrada para os seus repasses. Ela passa por conferência da HUB e só recebe depois do período de segurança.`,
          cta: { label: 'Ver meus ganhos', url: link(appUrl, data.url) },
          note: 'Se não foi você, fale com a HUB imediatamente e troque a sua senha.',
        }),
      }
    case 'alerta_financeiro':
      return {
        subject: `[Financeiro] ${String(data.title ?? 'Alerta')}`,
        ...layout({
          title: String(data.title ?? 'Alerta financeiro'),
          intro: String(data.body ?? ''),
          cta: { label: 'Abrir o painel financeiro', url: link(appUrl, data.url) },
        }),
      }
    default:
      return null
  }
}
