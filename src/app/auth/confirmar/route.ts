import { NextResponse, type NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'

/**
 * Destino dos links enviados por e-mail pelo Supabase Auth (modelos em
 * supabase/templates): confirmação de cadastro (type=email), troca de e-mail
 * (type=email_change) e recuperação de senha (type=recovery). Aceita também o
 * formato `code` do modelo padrão (só funciona no navegador que pediu o link).
 */
export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl
  const tokenHash = searchParams.get('token_hash')
  const code = searchParams.get('code')
  const supabase = await createClient()

  const type = searchParams.get('type')
  const url = request.nextUrl.clone()
  url.search = ''
  if (tokenHash && (type === 'email' || type === 'signup' || type === 'email_change')) {
    const ok = !(await supabase.auth.verifyOtp({ type: type === 'email_change' ? 'email_change' : 'email', token_hash: tokenHash })).error
    url.pathname = ok ? '/' : '/login'
    if (!ok) url.searchParams.set('erro', 'link')
    return NextResponse.redirect(url)
  }
  let ok = false
  if (tokenHash && type === 'recovery') {
    ok = !(await supabase.auth.verifyOtp({ type: 'recovery', token_hash: tokenHash })).error
  } else if (code) {
    ok = !(await supabase.auth.exchangeCodeForSession(code)).error
  }
  url.pathname = ok ? '/nova-senha' : '/recuperar'
  if (!ok) url.searchParams.set('erro', 'link')
  return NextResponse.redirect(url)
}
