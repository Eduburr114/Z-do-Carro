import type { NextRequest } from 'next/server'
import { getSession } from '@/lib/auth/session'
import { AppError, rpc } from '@/lib/rpc'

/**
 * Entrega um documento do credenciamento. O banco decide quem pode abrir: o
 * próprio prestador ou a equipe da HUB. Nada fica em cache nem em endereço público.
 */
export async function GET(_request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  if (!/^[0-9a-f-]{36}$/.test(id) || !(await getSession())) return new Response('Não encontrado', { status: 404 })
  try {
    const doc = await rpc<{ file_name: string; mime: string; content_base64: string }>('get_document', { p_id: id })
    return new Response(Buffer.from(doc.content_base64, 'base64'), {
      headers: {
        'Content-Type': doc.mime,
        'Content-Disposition': `inline; filename*=UTF-8''${encodeURIComponent(doc.file_name)}`,
        'Cache-Control': 'private, no-store',
      },
    })
  } catch (error) {
    if (error instanceof AppError) return new Response('Não encontrado', { status: 404 })
    throw error
  }
}
