'use client'

import { useState } from 'react'
import { Check, Copy } from 'lucide-react'
import { Button } from '@/components/ui/button'

export function CopyButton({ text, label = 'Copiar' }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text)
      setCopied(true)
      setTimeout(() => setCopied(false), 2500)
    } catch {
      setCopied(false)
    }
  }
  return (
    <Button variant="outline" size="sm" onClick={copy} className="shrink-0">
      {copied ? <Check /> : <Copy />}
      <span aria-live="polite">{copied ? 'Copiado' : label}</span>
    </Button>
  )
}
