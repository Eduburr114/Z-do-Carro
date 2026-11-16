import type { ReactNode } from 'react'
import { Star } from 'lucide-react'
import type { Rating } from '@/lib/types'

export function RatingBadge({ rating }: { rating: Rating }) {
  if (!rating.count || rating.average === null) return <span className="text-sm text-muted-foreground">Sem avaliações ainda</span>
  return (
    <span className="inline-flex items-center gap-1 text-sm font-semibold">
      <Star className="size-4 fill-brand text-brand" aria-hidden="true" />
      {rating.average.toLocaleString('pt-BR', { minimumFractionDigits: 1 })}
      <span className="font-normal text-muted-foreground">({rating.count})</span>
    </span>
  )
}

/** Linha "rótulo ........ valor" dos resumos de preço. */
export function Row({ label, value, strong }: { label: string; value: ReactNode; strong?: boolean }) {
  return (
    <div className={`flex items-baseline justify-between gap-4 py-1.5 ${strong ? 'text-base font-semibold' : 'text-sm'}`}>
      <span className={strong ? '' : 'text-muted-foreground'}>{label}</span>
      <span className="tabular-nums">{value}</span>
    </div>
  )
}

export function SectionTitle({ children }: { children: ReactNode }) {
  return <h2 className="mt-7 mb-3 text-lg font-semibold">{children}</h2>
}
