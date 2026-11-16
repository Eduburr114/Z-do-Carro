import { formatDate, formatMoney } from '@/lib/format'

/**
 * Volume confirmado por dia: série única, uma cor (o título nomeia a série),
 * barras finas ancoradas na base, dica por barra e tabela equivalente para
 * leitores de tela.
 */
export function DailyChart({ data }: { data: { day: string; volume: number; count: number }[] }) {
  if (data.length === 0) return <p className="px-4 py-6 text-sm text-muted-foreground">Sem pagamentos confirmados no período.</p>
  const max = Math.max(...data.map((d) => Number(d.volume)), 1)
  return (
    <div className="px-4 py-4">
      <div className="flex h-36 items-end justify-center gap-0.5 border-b border-border" aria-hidden="true">
        {data.map((d) => (
          <div key={d.day} className="group relative flex h-full max-w-10 flex-1 items-end">
            <div
              className="w-full rounded-t-[4px] bg-primary/80 group-hover:bg-primary"
              style={{ height: `${Math.max(2, (Number(d.volume) / max) * 100)}%` }}
            />
            <div className="pointer-events-none absolute bottom-full left-1/2 z-10 mb-1 hidden -translate-x-1/2 rounded-md bg-foreground px-2 py-1 text-xs whitespace-nowrap text-background group-hover:block">
              {formatDate(d.day)} · {formatMoney(d.volume)} · {d.count} pag.
            </div>
          </div>
        ))}
      </div>
      <div className="mt-1 flex justify-between text-xs text-muted-foreground" aria-hidden="true">
        <span>{formatDate(data[0].day)}</span>
        <span>máx. {formatMoney(max)}</span>
        <span>{formatDate(data.at(-1)!.day)}</span>
      </div>
      <table className="sr-only">
        <caption>Volume confirmado por dia</caption>
        <thead><tr><th>Dia</th><th>Volume</th><th>Pagamentos</th></tr></thead>
        <tbody>{data.map((d) => <tr key={d.day}><td>{formatDate(d.day)}</td><td>{formatMoney(d.volume)}</td><td>{d.count}</td></tr>)}</tbody>
      </table>
    </div>
  )
}
