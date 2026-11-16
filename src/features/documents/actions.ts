'use server'

import { z } from 'zod'
import { formAction } from '@/lib/action'
import { zId } from '@/lib/zod'

/** O arquivo chega em base64 (imagens já reduzidas no aparelho); o banco confere tipo e tamanho de novo. */
export const uploadDocument = formAction(
  z.object({
    kind: z.enum(['identity', 'address', 'certificate', 'equipment', 'other']),
    file_name: z.string().trim().min(1).max(200),
    mime: z.enum(['image/jpeg', 'image/png', 'image/webp', 'application/pdf'], 'Envie uma foto (JPG, PNG ou WebP) ou um PDF.'),
    content_base64: z.string().min(8).max(4_300_000, 'O arquivo precisa ter até 3 MB.').regex(/^[A-Za-z0-9+/=]+$/),
  }),
  async (input, { rpc }) => {
    await rpc('upload_document', { p_kind: input.kind, p_file_name: input.file_name, p_mime: input.mime, p_content_base64: input.content_base64 })
  },
)

export const deleteDocument = formAction(z.object({ id: zId }), async ({ id }, { rpc }) => {
  await rpc('delete_document', { p_id: id })
})
