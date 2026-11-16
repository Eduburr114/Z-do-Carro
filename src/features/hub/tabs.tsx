import { LinkTabs } from '@/components/ui/primitives'

const tabs = [
  { href: '/hub/ajustes', label: 'Regras e pagamento' },
  { href: '/hub/ajustes/catalogo', label: 'Catálogo e preços' },
  { href: '/hub/ajustes/comissoes', label: 'Comissões e promoções' },
  { href: '/hub/ajustes/equipe', label: 'Equipe' },
]

export function SettingsTabs({ current }: { current: string }) {
  return <LinkTabs tabs={tabs} current={current} />
}

export const financeTabs = [
  { href: '/hub/financeiro', label: 'Painel' },
  { href: '/hub/financeiro/pagamentos', label: 'Pagamentos' },
  { href: '/hub/financeiro/repasses', label: 'Repasses' },
  { href: '/hub/financeiro/disputas', label: 'Disputas' },
  { href: '/hub/financeiro/contas', label: 'Contas Pix' },
  { href: '/hub/financeiro/conciliacao', label: 'Conciliação' },
]

export function FinanceTabs({ current }: { current: string }) {
  return <LinkTabs tabs={financeTabs} current={current} />
}
