import type { Role } from '@/lib/types'
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
      { href: '/hub', label: 'Visão geral', icon: 'gauge', exact: true },
      { href: '/hub/prestadores', label: 'Prestadores', icon: 'people' },
      { href: '/hub/pedidos', label: 'Pedidos', icon: 'orders' },
      { href: '/hub/ajustes', label: 'Ajustes', icon: 'settings' },
      { href: '/conta', label: 'Conta', icon: 'user' },
    ],
  },
}
