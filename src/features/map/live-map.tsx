'use client'

import { useEffect, useRef } from 'react'
import type { Map as LeafletMap } from 'leaflet'
import 'leaflet/dist/leaflet.css'

export type MapPoint = { lat: number; lng: number; label: string; kind: 'car' | 'provider' }

const colors = { car: '#10151f', provider: '#ffc400' }

/**
 * Mapa do atendimento: o local do carro e, quando houver, a posição do
 * prestador. Usa os quadros públicos do OpenStreetMap, adequados ao volume de
 * um piloto; para escala, troque por um provedor contratado.
 */
export function LiveMap({ points }: { points: MapPoint[] }) {
  const container = useRef<HTMLDivElement>(null)
  const map = useRef<LeafletMap | null>(null)
  const key = points.map((p) => `${p.kind}:${p.lat.toFixed(5)},${p.lng.toFixed(5)}`).join('|')

  useEffect(() => {
    let cancelled = false
    import('leaflet').then((L) => {
      if (cancelled || !container.current) return
      if (!map.current) {
        map.current = L.map(container.current, { zoomControl: false, attributionControl: true, scrollWheelZoom: false })
        L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
          maxZoom: 19,
          attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">OpenStreetMap</a>',
        }).addTo(map.current)
      }
      const current = map.current
      current.eachLayer((layer) => {
        if (layer instanceof L.CircleMarker) layer.remove()
      })
      for (const point of points) {
        L.circleMarker([point.lat, point.lng], { radius: 10, weight: 3, color: '#10151f', fillColor: colors[point.kind], fillOpacity: 1 })
          .bindTooltip(point.label, { permanent: true, direction: 'top', offset: [0, -10] })
          .addTo(current)
      }
      if (points.length === 1) current.setView([points[0].lat, points[0].lng], 15)
      else current.fitBounds(L.latLngBounds(points.map((p) => [p.lat, p.lng] as [number, number])), { padding: [40, 40], maxZoom: 16 })
    })
    return () => {
      cancelled = true
    }
    // `key` resume os pontos; evita refazer o mapa a cada atualização sem mudança.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key])

  useEffect(
    () => () => {
      map.current?.remove()
      map.current = null
    },
    [],
  )

  return (
    <div
      ref={container}
      role="img"
      aria-label={`Mapa com ${points.map((p) => p.label).join(' e ')}`}
      className="relative z-0 h-56 w-full overflow-hidden rounded-(--radius-panel) border border-border bg-surface-2"
    />
  )
}
