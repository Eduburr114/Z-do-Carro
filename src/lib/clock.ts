/**
 * Hora da requisição. Páginas do servidor renderizam uma vez por requisição,
 * então comparar prazos com "agora" é seguro ali; a função existe para deixar
 * isso explícito (e testável).
 */
export function requestTime(): number {
  return Date.now()
}
