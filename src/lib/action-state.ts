export type ActionState = {
  ok: boolean
  message?: string
  fieldErrors?: Record<string, string>
  /** Dados devolvidos ao formulário (por exemplo, o id criado). */
  data?: Record<string, unknown>
  /** Muda a cada resposta, para o cliente reagir mesmo a resultados iguais. */
  at?: number
}

export const initialState: ActionState = { ok: false }

export type FormAction = (state: ActionState, formData: FormData) => Promise<ActionState>
