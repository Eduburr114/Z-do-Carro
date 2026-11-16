import { NextResponse, type NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'

/**
 * Destino do link de recuperação de senha enviado por e-mail. Aceita os dois
 * formatos do Supabase: token_hash (modelo de e-mail recomendado, funciona em
 * qualquer aparelho) e code (modelo padrão, só no navegador que pediu o link).
 */
export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl
  const tokenHash = searchParams.get('token_hash')
  const code = searchParams.get('code')
  const supabase = await createClient()

  let ok = false
  if (tokenHash && searchParams.get('type') === 'recovery') {
    ok = !(await supabase.auth.verifyOtp({ type: 'recovery', token_hash: tokenHash })).error
  } else if (code) {
    ok = !(await supabase.auth.exchangeCodeForSession(code)).error
  }
  const url = request.nextUrl.clone()
  url.search = ''
  url.pathname = ok ? '/nova-senha' : '/recuperar'
  if (!ok) url.searchParams.set('erro', 'link')
  return NextResponse.redirect(url)
}
