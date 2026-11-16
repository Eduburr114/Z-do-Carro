'use client'

import { useEffect, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { initialState } from '@/lib/action-state'
import { setOnline, updatePosition } from './actions'

function currentPosition(): Promise<{ lat: number; lng: number } | null> {
  return new Promise((resolve) => {
    if (!('geolocation' in navigator)) return resolve(null)
    navigator.geolocation.getCurrentPosition(
      (position) => resolve({ lat: position.coords.latitude, lng: position.coords.longitude }),
      () => resolve(null),
      { enableHighAccuracy: true, timeout: 8000, maximumAge: 60_000 },
    )
  })
}

/** Ficar disponível é sempre iniciativa do prestador; a posição só é lida nesse momento. */
export function OnlineToggle({ online }: { online: boolean }) {
  const [pending, startTransition] = useTransition()
  const router = useRouter()
  const toggle = () =>
    startTransition(async () => {
      const data = new FormData()
      data.set('online', online ? 'no' : 'yes')
      if (!online) {
        const position = await currentPosition()
        if (position) {
          data.set('lat', String(position.lat))
          data.set('lng', String(position.lng))
        }
      }
      const result = await setOnline(initialState, data)
      if (!result.ok) toast.error(result.message ?? 'Não foi possível alterar a disponibilidade.')
      router.refresh()
    })
  return (
    <div className={`rounded-(--radius-panel) px-4 py-4 ${online ? 'bg-success-surface' : 'bg-surface-2'}`}>
      <div className="flex items-center gap-3">
        <span className={`size-3 shrink-0 rounded-full ${online ? 'bg-success' : 'bg-muted-foreground'}`} aria-hidden="true" />
        <div className="min-w-0 flex-1">
          <p className="text-lg font-semibold">{online ? 'Você está disponível' : 'Você está indisponível'}</p>
          <p className="text-sm text-muted-foreground">
            {online ? 'Novos pedidos da sua região aparecem abaixo.' : 'Fique disponível quando quiser receber pedidos.'}
          </p>
        </div>
      </div>
      <Button onClick={toggle} disabled={pending} aria-busy={pending} variant={online ? 'outline' : 'primary'} size="lg" className="mt-3 w-full">
        {pending ? 'Aguarde…' : online ? 'Ficar indisponível' : 'Ficar disponível'}
      </Button>
    </div>
  )
}

/** Envia a posição a cada 30 s enquanto a tela está aberta (disponível ou em atendimento). */
export function PositionBeacon() {
  const [denied, setDenied] = useState(false)
  useEffect(() => {
    if (denied) return
    let stopped = false
    const send = async () => {
      if (document.visibilityState !== 'visible') return
      const position = await currentPosition()
      if (stopped) return
      if (!position) return setDenied(true)
      await updatePosition(position.lat, position.lng)
    }
    const timer = setInterval(send, 30_000)
    return () => {
      stopped = true
      clearInterval(timer)
    }
  }, [denied])
  return null
}
