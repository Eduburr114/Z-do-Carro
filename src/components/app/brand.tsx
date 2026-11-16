/** Marca: uma roda em amarelo de sinalização sobre o asfalto. */
export function WheelMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 512 512" aria-hidden="true" className={className}>
      <rect width="512" height="512" rx="112" fill="#10151f" />
      <circle cx="256" cy="256" r="150" fill="none" stroke="#ffc400" strokeWidth="44" />
      <circle cx="256" cy="256" r="46" fill="#ffc400" />
      <path d="M256 150v60M256 302v60M150 256h60M302 256h60" stroke="#ffc400" strokeWidth="26" strokeLinecap="round" />
    </svg>
  )
}

export function Wordmark({ className }: { className?: string }) {
  return (
    <span className={`inline-flex items-center gap-2 font-display font-semibold ${className ?? ''}`}>
      <WheelMark className="size-8 rounded-lg" />
      Zé do Carro
    </span>
  )
}
