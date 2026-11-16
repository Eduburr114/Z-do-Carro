'use client'

import { useEffect, useState, useTransition } from 'react'
import { Button } from '@/components/ui/button'
import { deletePushSubscription, savePushSubscription } from '@/features/account/actions'

function urlBase64ToUint8Array(base64: string): Uint8Array<ArrayBuffer> {
  const padding = '='.repeat((4 - (base64.length % 4)) % 4)
  const raw = atob((base64 + padding).replace(/-/g, '+').replace(/_/g, '/'))
  const output = new Uint8Array(new ArrayBuffer(raw.length))
  for (let i = 0; i < raw.length; i++) output[i] = raw.charCodeAt(i)
  return output
}

type State = 'checking' | 'unsupported' | 'needs-install' | 'denied' | 'off' | 'on' | 'not-configured'

/**
 * Ativa os avisos push neste aparelho. No iPhone, só funciona com o
 * aplicativo instalado na Tela de Início (iOS 16.4 ou mais recente), e o pedido de
 * permissão precisa partir de um toque no botão.
 */
export function PushToggle({ vapidKey }: { vapidKey: string | null }) {
  const [state, setState] = useState<State>('checking')
  const [message, setMessage] = useState<string | null>(null)
  const [pending, startTransition] = useTransition()

  useEffect(() => {
    const run = async () => {
      if (!vapidKey) return setState('not-configured')
      const standalone = window.matchMedia('(display-mode: standalone)').matches || (navigator as Navigator & { standalone?: boolean }).standalone === true
      const isIos = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
      if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) {
        return setState(isIos && !standalone ? 'needs-install' : 'unsupported')
      }
      if (Notification.permission === 'denied') return setState('denied')
      const registration = await navigator.serviceWorker.getRegistration('/')
      const subscription = await registration?.pushManager.getSubscription()
      setState(subscription ? 'on' : 'off')
    }
    run().catch(() => setState('unsupported'))
  }, [vapidKey])

  const enable = () =>
    startTransition(async () => {
      setMessage(null)
      try {
        const permission = await Notification.requestPermission()
        if (permission !== 'granted') {
          setState(permission === 'denied' ? 'denied' : 'off')
          return
        }
        const registration = await navigator.serviceWorker.register('/sw.js', { scope: '/', updateViaCache: 'none' })
        await navigator.serviceWorker.ready
        const subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(vapidKey!) })
        const result = await savePushSubscription(subscription.toJSON())
        if (!result.ok) {
          await subscription.unsubscribe()
          setMessage(result.message ?? 'Não foi possível ativar.')
          return
        }
        setState('on')
      } catch {
        setMessage('Não foi possível ativar neste aparelho.')
      }
    })

  const disable = () =>
    startTransition(async () => {
      const registration = await navigator.serviceWorker.getRegistration('/')
      const subscription = await registration?.pushManager.getSubscription()
      if (subscription) {
        await deletePushSubscription(subscription.endpoint)
        await subscription.unsubscribe()
      }
      setState('off')
    })

  const text: Record<State, string> = {
    checking: 'Verificando este aparelho…',
    unsupported: 'Este navegador não recebe avisos push. Os avisos continuam disponíveis dentro do aplicativo.',
    'needs-install': 'No iPhone, primeiro instale o aplicativo: toque em Compartilhar e depois em “Adicionar à Tela de Início”. Abra pelo ícone e volte aqui.',
    denied: 'Os avisos foram bloqueados neste aparelho. Libere nas configurações do navegador ou do celular.',
    off: 'Receba um aviso no aparelho quando houver novidade nos seus pedidos, mesmo com o aplicativo fechado.',
    on: 'Avisos ativados neste aparelho.',
    'not-configured': 'Os avisos push ainda não foram habilitados no servidor. Os avisos continuam aparecendo dentro do aplicativo.',
  }

  return (
    <div className="space-y-3">
      <p className="text-sm">{text[state]}</p>
      {state === 'off' ? <Button onClick={enable} disabled={pending}>{pending ? 'Ativando…' : 'Ativar neste aparelho'}</Button> : null}
      {state === 'on' ? <Button variant="outline" onClick={disable} disabled={pending}>Desativar neste aparelho</Button> : null}
      {message ? <p className="text-sm text-danger">{message}</p> : null}
    </div>
  )
}
