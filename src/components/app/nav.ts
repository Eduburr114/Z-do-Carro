import type { Role, StaffRole } from '@/lib/types'
import type { NavItem } from './bottom-nav'

export const areaOf: Record<Role, { label: string; home: string; wide: boolean; nav: NavItem[] }> = {
  customer: {
    label: 'Cliente',
    home: '/cliente',
    wide: false,
    nav: [
      { href: '/cliente', label: 'Início', icon: 'home', exact: true },
      { href: '/cliente/pedidos', label: 'Pedidos', icon: 'orders' },
      { href: '/cliente/veiculos', label: 'Veículos', icon: 'car' },
      { href: '/conta', label: 'Conta', icon: 'user' },
    ],
  },
  provider: {
    label: 'Prestador',
    home: '/prestador',
    wide: false,
    nav: [
      { href: '/prestador', label: 'Início', icon: 'home', exact: true },
      { href: '/prestador/ganhos', label: 'Ganhos', icon: 'wallet' },
      { href: '/prestador/contrato', label: 'Contrato', icon: 'contract' },
      { href: '/conta', label: 'Conta', icon: 'user' },
    ],
  },
  hub_admin: {
    label: 'HUB',
    home: '/hub',
    wide: true,
    nav: [
      { href: '/hub', label: 'Visão geral', icon: 'gauge', exact: true, staff: 'admin' },
      { href: '/hub/prestadores', label: 'Prestadores', icon: 'people', staff: 'admin' },
      { href: '/hub/pedidos', label: 'Pedidos', icon: 'orders', staff: 'admin' },
      { href: '/hub/financeiro', label: 'Financeiro', icon: 'wallet', staff: 'finance' },
      { href: '/hub/ajustes', label: 'Ajustes', icon: 'settings', staff: 'admin' },
      { href: '/conta', label: 'Conta', icon: 'user', hideForAdmin: true },
    ],
  },
}

/** Itens da navegação conforme os papéis internos de quem está na HUB. */
export function navFor(role: Role, staff: StaffRole[]): NavItem[] {
  return areaOf[role].nav.filter((item) => (!item.staff || staff.includes(item.staff)) && !(item.hideForAdmin && staff.includes('admin')))
}
