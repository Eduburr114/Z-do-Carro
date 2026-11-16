import { FileText } from 'lucide-react'
import { ActionForm, SubmitButton } from '@/components/ui/form'
import { documentKind, formatSize } from '@/lib/format'
import type { ProviderDocument } from '@/lib/types'
import { deleteDocument } from './actions'

/** Lista de documentos; cada um abre em nova aba por uma rota que confere o acesso. */
export function DocumentList({ documents, removable }: { documents: ProviderDocument[]; removable?: boolean }) {
  if (documents.length === 0) return <p className="px-4 py-4 text-sm text-muted-foreground">Nenhum documento enviado.</p>
  return (
    <ul className="divide-y divide-border">
      {documents.map((doc) => (
        <li key={doc.id} className="flex items-center gap-3 px-4 py-3">
          <FileText className="size-5 shrink-0 text-muted-foreground" aria-hidden="true" />
          <div className="min-w-0 flex-1">
            <a href={`/documentos/${doc.id}`} target="_blank" rel="noreferrer" className="block truncate font-semibold text-primary underline-offset-4 hover:underline">
              {documentKind[doc.kind] ?? doc.kind}
            </a>
            <p className="truncate text-sm text-muted-foreground">{doc.file_name} · {formatSize(doc.size)}</p>
          </div>
          {removable ? (
            <ActionForm action={deleteDocument} successMessage="Documento removido.">
              <input type="hidden" name="id" value={doc.id} />
              <SubmitButton variant="ghost" size="sm">Remover</SubmitButton>
            </ActionForm>
          ) : null}
        </li>
      ))}
    </ul>
  )
}
