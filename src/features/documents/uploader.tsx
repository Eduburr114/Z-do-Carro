'use client'

import { useRef, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { Upload } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { controlClass } from '@/components/ui/form'
import { initialState } from '@/lib/action-state'
import { documentKind } from '@/lib/format'
import { uploadDocument } from './actions'

const MAX_BYTES = 3 * 1024 * 1024

function toBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer)
  let binary = ''
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(binary)
}

/** Fotos de celular passam de 3 MB com facilidade: reduz para até 1600 px e JPEG antes de enviar. */
async function shrinkImage(file: File): Promise<Blob> {
  const bitmap = await createImageBitmap(file)
  const scale = Math.min(1, 1600 / Math.max(bitmap.width, bitmap.height))
  const canvas = document.createElement('canvas')
  canvas.width = Math.round(bitmap.width * scale)
  canvas.height = Math.round(bitmap.height * scale)
  canvas.getContext('2d')!.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  bitmap.close()
  return new Promise((resolve, reject) => canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('canvas'))), 'image/jpeg', 0.82))
}

export function DocumentUploader() {
  const [pending, startTransition] = useTransition()
  const [kind, setKind] = useState('identity')
  const input = useRef<HTMLInputElement>(null)
  const router = useRouter()

  const send = (file: File) =>
    startTransition(async () => {
      try {
        let blob: Blob = file
        let mime = file.type
        let name = file.name
        if (file.type.startsWith('image/')) {
          blob = await shrinkImage(file)
          mime = 'image/jpeg'
          name = name.replace(/\.[^.]+$/, '') + '.jpg'
        }
        if (blob.size > MAX_BYTES) return void toast.error('O arquivo precisa ter até 3 MB.')
        const data = new FormData()
        data.set('kind', kind)
        data.set('file_name', name)
        data.set('mime', mime)
        data.set('content_base64', toBase64(await blob.arrayBuffer()))
        const result = await uploadDocument(initialState, data)
        if (result.ok) toast.success('Documento enviado.')
        else toast.error(result.fieldErrors?.mime ?? result.fieldErrors?.content_base64 ?? result.message ?? 'Não foi possível enviar.')
        router.refresh()
      } catch {
        toast.error('Não foi possível ler este arquivo. Tente outra foto ou um PDF.')
      } finally {
        if (input.current) input.current.value = ''
      }
    })

  return (
    <div className="grid grid-cols-[1fr_auto] items-end gap-2">
      <div className="space-y-1.5">
        <label htmlFor="doc-kind" className="block text-sm font-semibold">Tipo do documento</label>
        <select id="doc-kind" className={controlClass} value={kind} onChange={(event) => setKind(event.target.value)} disabled={pending}>
          {Object.entries(documentKind).map(([value, label]) => (
            <option key={value} value={value}>{label}</option>
          ))}
        </select>
      </div>
      <input
        ref={input}
        type="file"
        accept="image/jpeg,image/png,image/webp,application/pdf"
        className="sr-only"
        aria-label="Escolher arquivo do documento"
        onChange={(event) => {
          const file = event.target.files?.[0]
          if (file) send(file)
        }}
      />
      <Button variant="secondary" onClick={() => input.current?.click()} disabled={pending} aria-busy={pending}>
        <Upload /> {pending ? 'Enviando…' : 'Enviar'}
      </Button>
    </div>
  )
}
