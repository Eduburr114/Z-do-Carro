import { z } from 'zod'

export const zId = z.uuid('Identificador inválido.')
/** Campo oculto de coordenada: vazio vira nulo. */
export const zCoord = z.string().optional().transform((v) => (v && Number.isFinite(Number(v)) ? Number(v) : null))
/** Valor em reais digitado como "1.250,00" ou "1250.00". */
export const zMoney = z
  .string()
  .trim()
  .transform((v) => (v.includes(',') ? v.replace(/\./g, '').replace(',', '.') : v))
  .pipe(z.string().regex(/^\d{1,6}(\.\d{1,2})?$/, 'Informe um valor válido.'))
  .transform(Number)
  .refine((v) => v > 0, 'Informe um valor maior que zero.')
export const zInt = (min: number, max: number, message: string) =>
  z.string().trim().regex(/^\d+$/, message).transform(Number).refine((v) => v >= min && v <= max, message)
