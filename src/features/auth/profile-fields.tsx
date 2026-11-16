import Link from 'next/link'
import { CheckboxField, Field } from '@/components/ui/form'

/** Escolha do tipo de conta e dados básicos, usados no cadastro e ao completar o perfil. */
export function ProfileFields({ defaultRole }: { defaultRole: 'customer' | 'provider' }) {
  const options = [
    { value: 'customer', title: 'Quero pedir serviços', text: 'Para o meu carro' },
    { value: 'provider', title: 'Quero atender', text: 'Sou profissional' },
  ]
  return (
    <>
      <fieldset>
        <legend className="mb-1.5 block text-sm font-semibold">Como você vai usar o aplicativo?</legend>
        <div className="grid grid-cols-2 gap-2">
          {options.map((option) => (
            <label key={option.value} className="cursor-pointer rounded-(--radius-control) border border-border bg-surface px-3 py-3 has-checked:border-foreground has-checked:bg-brand has-checked:text-brand-foreground">
              <input type="radio" name="role" value={option.value} defaultChecked={option.value === defaultRole} className="sr-only" />
              <span className="block text-sm font-semibold">{option.title}</span>
              <span className="block text-sm opacity-75">{option.text}</span>
            </label>
          ))}
        </div>
      </fieldset>
      <Field label="Nome completo" name="full_name" autoComplete="name" required />
      <Field label="Celular com DDD" name="phone" type="tel" inputMode="tel" autoComplete="tel-national" placeholder="(98) 90000-0000" required />
    </>
  )
}

/** Aceite dos Termos de Uso e da Política de Privacidade; a versão aceita fica gravada no cadastro. */
export function TermsField() {
  return (
    <div>
      <CheckboxField name="terms" label="Li e aceito os Termos de Uso e a Política de Privacidade" />
      <p className="mt-1.5 pl-8 text-sm text-muted-foreground">
        Leia os{' '}
        <Link href="/termos" target="_blank" className="font-semibold text-primary underline-offset-4 hover:underline">Termos de Uso</Link>
        {' '}e a{' '}
        <Link href="/privacidade" target="_blank" className="font-semibold text-primary underline-offset-4 hover:underline">Política de Privacidade</Link>.
      </p>
    </div>
  )
}
