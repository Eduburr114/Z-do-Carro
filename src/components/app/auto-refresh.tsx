'use client'

import { useEffect } from 'react'
import { useRouter } from 'next/navigation'

/** Atualiza a tela de tempos em tempos enquanto ela está visível (acompanhamento do pedido). */
export function AutoRefresh({ seconds = 8 }: { seconds?: number }) {
  const router = useRouter()
  useEffect(() => {
    const timer = setInterval(() => {
      if (document.visibilityState === 'visible') router.refresh()
    }, seconds * 1000)
    return () => clearInterval(timer)
  }, [router, seconds])
  return null
}
