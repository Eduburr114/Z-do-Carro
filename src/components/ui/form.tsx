'use client'

import { createContext, startTransition, useActionState, useContext, useEffect, useId, useRef, type ReactNode, type InputHTMLAttributes, type SelectHTMLAttributes, type TextareaHTMLAttributes } from 'react'
import { useRouter } from 'next/navigation'
import { toast } from 'sonner'
import { initialState, type ActionState, type FormAction } from '@/lib/action-state'
import { cn } from '@/lib/utils'
import { Button, type ButtonProps } from './button'

const FormContext = createContext<{ state: ActionState; pending: boolean }>({ state: initialState, pending: false })

export const controlClass =
  'block w-full rounded-(--radius-control) border border-border bg-surface px-3 h-11 text-foreground placeholder:text-muted-foreground/70 disabled:opacity-60 aria-[invalid=true]:border-danger'

type ActionFormProps = {
  action: FormAction
  children: ReactNode
  className?: string
  /** Texto do aviso de sucesso; sem ele, nenhum aviso é mostrado. */
  successMessage?: string
  onSuccess?: (state: ActionState) => void
  /** Para onde ir depois do sucesso. Aceita "{id}" e outros campos de state.data. */
  redirectTo?: string
  resetOnSuccess?: boolean
}

/** Formulário ligado a uma Server Action: mostra erros por campo, avisa o resultado e atualiza a tela. */
export function ActionForm({ action, children, className, successMessage, onSuccess, redirectTo, resetOnSuccess = true }: ActionFormProps) {
  // O aviso sai assim que a resposta chega, mesmo que o próprio formulário
  // deixe de existir na tela atualizada (ex.: o botão "Conferir" some).
  const [state, formAction, pending] = useActionState(async (previous: ActionState, formData: FormData) => {
    const result = await action(previous, formData)
    if (result.ok && successMessage) toast.success(successMessage)
    return result
  }, initialState)
  const router = useRouter()
  const formRef = useRef<HTMLFormElement>(null)
  const handled = useRef<number | undefined>(undefined)
  const onSuccessRef = useRef(onSuccess)
  useEffect(() => {
    onSuccessRef.current = onSuccess
  })

  useEffect(() => {
    if (!state.at || handled.current === state.at) return
    handled.current = state.at
    if (!state.ok) return
    if (resetOnSuccess) formRef.current?.reset()
    onSuccessRef.current?.(state)
    if (redirectTo) {
      router.push(redirectTo.replace(/\{(\w+)\}/g, (_, key: string) => String(state.data?.[key] ?? '')))
    } else {
      router.refresh()
    }
  }, [state, redirectTo, resetOnSuccess, router])

  return (
    <FormContext.Provider value={{ state, pending }}>
      <form
        ref={formRef}
        action={formAction}
        // Envio manual: o React limpa o formulário ao fim de toda action enviada
        // por `action`, inclusive quando a validação falha. Assim o que a pessoa
        // digitou fica na tela e só é limpo em caso de sucesso (resetOnSuccess).
        onSubmit={(event) => {
          event.preventDefault()
          const data = new FormData(event.currentTarget)
          startTransition(() => formAction(data))
        }}
        className={cn('space-y-4', className)}
        noValidate
      >
        {children}
        {!state.ok && state.message ? (
          <p role="alert" className="rounded-(--radius-control) bg-danger-surface px-3 py-2 text-sm font-medium text-danger">
            {state.message}
          </p>
        ) : null}
      </form>
    </FormContext.Provider>
  )
}

export function SubmitButton({ children, ...props }: ButtonProps) {
  const { pending } = useContext(FormContext)
  return (
    <Button type="submit" disabled={pending || props.disabled} aria-busy={pending} {...props}>
      {pending ? 'Aguarde…' : children}
    </Button>
  )
}

type FieldShellProps = { label: string; name: string; hint?: string; className?: string }

function useField(name: string) {
  const { state } = useContext(FormContext)
  const id = useId()
  const error = state.fieldErrors?.[name]
  return { id, error }
}

function FieldShell({ id, label, hint, error, className, children }: Omit<FieldShellProps, 'name'> & { id: string; error?: string; children: ReactNode }) {
  return (
    <div className={cn('space-y-1.5', className)}>
      <label htmlFor={id} className="block text-sm font-semibold text-foreground">
        {label}
      </label>
      {children}
      {error ? (
        <p id={`${id}-erro`} className="text-sm font-medium text-danger">
          {error}
        </p>
      ) : hint ? (
        <p className="text-sm text-muted-foreground">{hint}</p>
      ) : null}
    </div>
  )
}

export function Field({ label, name, hint, className, ...props }: FieldShellProps & InputHTMLAttributes<HTMLInputElement>) {
  const { id, error } = useField(name)
  return (
    <FieldShell id={id} label={label} hint={hint} error={error} className={className}>
      <input id={id} name={name} aria-invalid={Boolean(error)} aria-describedby={error ? `${id}-erro` : undefined} className={controlClass} {...props} />
    </FieldShell>
  )
}

/** Campo de valor em reais: teclado numérico no celular, aceita "1.250,00". */
export function MoneyField(props: FieldShellProps & InputHTMLAttributes<HTMLInputElement>) {
  return <Field inputMode="decimal" autoComplete="off" placeholder="0,00" {...props} />
}

export function TextareaField({ label, name, hint, className, ...props }: FieldShellProps & TextareaHTMLAttributes<HTMLTextAreaElement>) {
  const { id, error } = useField(name)
  return (
    <FieldShell id={id} label={label} hint={hint} error={error} className={className}>
      <textarea id={id} name={name} rows={3} aria-invalid={Boolean(error)} className={cn(controlClass, 'h-auto py-2')} {...props} />
    </FieldShell>
  )
}

export function SelectField({ label, name, hint, className, children, ...props }: FieldShellProps & SelectHTMLAttributes<HTMLSelectElement>) {
  const { id, error } = useField(name)
  return (
    <FieldShell id={id} label={label} hint={hint} error={error} className={className}>
      <select id={id} name={name} aria-invalid={Boolean(error)} className={controlClass} {...props}>
        {children}
      </select>
    </FieldShell>
  )
}

export function CheckboxField({ label, name, hint, ...props }: { label: string; name: string; hint?: string } & InputHTMLAttributes<HTMLInputElement>) {
  const { id, error } = useField(name.replace(/\[\]$/, ''))
  return (
    <div className="flex items-start gap-3">
      <input id={id} name={name} type="checkbox" aria-invalid={Boolean(error)} aria-describedby={error ? `${id}-erro` : undefined} className="mt-0.5 size-5 shrink-0 rounded border-border accent-(--primary)" {...props} />
      <label htmlFor={id} className="text-sm">
        <span className="font-semibold">{label}</span>
        {hint ? <span className="block text-muted-foreground">{hint}</span> : null}
        {error ? <span id={`${id}-erro`} className="block font-medium text-danger">{error}</span> : null}
      </label>
    </div>
  )
}
