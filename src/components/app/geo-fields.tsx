'use client'

import { useState } from 'react'
import { LocateFixed } from 'lucide-react'
import { Button } from '@/components/ui/button'

type Geo = { state: 'idle' | 'asking' | 'ok' | 'denied'; lat?: number; lng?: number }

/**
 * Campos ocultos lat/lng preenchidos com a localização do aparelho, sempre a
 * pedido do usuário. Sem permissão, o formulário segue só com o texto informado.
 */
export function GeoFields({ label = 'Usar minha localização', hint }: { label?: string; hint?: string }) {
  const [geo, setGeo] = useState<Geo>({ state: 'idle' })
  const locate = () => {
    if (!('geolocation' in navigator)) return setGeo({ state: 'denied' })
    setGeo({ state: 'asking' })
    navigator.geolocation.getCurrentPosition(
      (position) => setGeo({ state: 'ok', lat: position.coords.latitude, lng: position.coords.longitude }),
      () => setGeo({ state: 'denied' }),
      { enableHighAccuracy: true, timeout: 10_000, maximumAge: 60_000 },
    )
  }
  return (
    <div className="space-y-1.5">
      <input type="hidden" name="lat" value={geo.lat ?? ''} />
      <input type="hidden" name="lng" value={geo.lng ?? ''} />
      <Button variant="outline" onClick={locate} disabled={geo.state === 'asking'} className="w-full">
        <LocateFixed />
        {geo.state === 'asking' ? 'Localizando…' : geo.state === 'ok' ? 'Localização capturada' : label}
      </Button>
      <p className="text-sm text-muted-foreground" role="status">
        {geo.state === 'denied'
          ? 'Não foi possível obter a localização. Você pode continuar sem ela.'
          : geo.state === 'ok'
            ? 'Usaremos este ponto para calcular a distância.'
            : hint}
      </p>
    </div>
  )
}
