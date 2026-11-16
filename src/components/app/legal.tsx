import type { ReactNode } from 'react'
import { Notice } from '@/components/ui/primitives'
import { TERMS_VERSION } from '@/lib/terms'

export function LegalDocument({ title, children }: { title: string; children: ReactNode }) {
  return (
    <article>
      <p className="text-sm text-muted-foreground">Versão {TERMS_VERSION}</p>
      <h1 className="text-[1.75rem] font-semibold text-balance">{title}</h1>
      <Notice tone="warning" className="mt-4">
        Minuta para revisão jurídica. Os campos entre colchetes ainda precisam ser preenchidos pela HUB antes da operação com o público.
      </Notice>
      <div className="mt-6 space-y-6 leading-relaxed [&_h2]:mb-2 [&_h2]:text-lg [&_h2]:font-semibold [&_li]:ml-5 [&_li]:list-disc [&_p+p]:mt-2 [&_ul]:mt-2 [&_ul]:space-y-1">
        {children}
      </div>
    </article>
  )
}
