import 'jsr:@supabase/functions-js/edge-runtime.d.ts'

const SUPABASE_URL=Deno.env.get('SUPABASE_URL')??''
const SERVICE_ROLE=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')??''
const RECOVERY_EMAIL_FROM='escolalendaria07@gmail.com'
const RECOVERY_EMAIL_APP_PASSWORD=String(Deno.env.get('PSF_RECOVERY_EMAIL_APP_PASSWORD')??'').replace(/\s+/g,'')

const CORS={
  'Access-Control-Allow-Origin':'https://jogoslendarios.adadpsf.shop',
  'Access-Control-Allow-Headers':'authorization, content-type',
  'Access-Control-Allow-Methods':'GET, POST, OPTIONS',
  'Cache-Control':'no-store',
  'X-Content-Type-Options':'nosniff',
  'Vary':'Origin',
}

function out(body:unknown,status=200){
  return new Response(JSON.stringify(body),{status,headers:{...CORS,'Content-Type':'application/json; charset=utf-8'}})
}
function fail(message:string,status=400){return out({error:message},status)}
async function rpc(name:string,args:Record<string,unknown>){
  const r=await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`,{
    method:'POST',
    headers:{apikey:SERVICE_ROLE,Authorization:`Bearer ${SERVICE_ROLE}`,'Content-Type':'application/json',Accept:'application/json'},
    body:JSON.stringify(args),
  })
  const raw=await r.text();let data:any=null
  try{data=raw?JSON.parse(raw):null}catch{data=raw}
  if(!r.ok)throw new Error(data?.message||data?.hint||data?.error||'Falha no banco.')
  return data
}
function base64Utf8(value:string){
  const bytes=new TextEncoder().encode(value);let binary=''
  for(let i=0;i<bytes.length;i+=0x8000)binary+=String.fromCharCode(...bytes.subarray(i,Math.min(i+0x8000,bytes.length)))
  return btoa(binary)
}
async function smtpRead(conn:any){
  const decoder=new TextDecoder(),buffer=new Uint8Array(4096);let raw=''
  while(raw.length<65536){
    const n=await conn.read(buffer)
    if(n===null)throw new Error('Ligação SMTP encerrada.')
    raw+=decoder.decode(buffer.subarray(0,n),{stream:true})
    const lines=raw.split(/\r?\n/)
    for(let i=lines.length-2;i>=0;i--){if(!lines[i])continue;if(/^\d{3} /.test(lines[i]))return raw;break}
  }
  throw new Error('Resposta SMTP demasiado grande.')
}
async function smtpCommand(conn:any,command:string|null,accepted:number[]){
  if(command!==null)await conn.write(new TextEncoder().encode(command+'\r\n'))
  const response=await smtpRead(conn),code=Number(response.slice(0,3))
  if(!accepted.includes(code))throw new Error(`SMTP ${code||'inválido'}`)
  return response
}
async function sendRecoveryEmail(to:string,code:string){
  if(!RECOVERY_EMAIL_APP_PASSWORD)throw new Error('Credencial SMTP ainda não configurada neste projeto.')
  const conn=await Deno.connectTls({hostname:'smtp.gmail.com',port:465})
  try{
    await smtpCommand(conn,null,[220])
    await smtpCommand(conn,'EHLO jogoslendarios.adadpsf.shop',[250])
    await smtpCommand(conn,'AUTH LOGIN',[334])
    await smtpCommand(conn,btoa(RECOVERY_EMAIL_FROM),[334])
    await smtpCommand(conn,btoa(RECOVERY_EMAIL_APP_PASSWORD),[235])
    await smtpCommand(conn,`MAIL FROM:<${RECOVERY_EMAIL_FROM}>`,[250])
    await smtpCommand(conn,`RCPT TO:<${to}>`,[250,251])
    await smtpCommand(conn,'DATA',[354])
    const subject='Código de recuperação do PIN — Jogos Lendários'
    const body=[
      'Jogos Lendários','',
      `O seu código temporário para recuperar o PIN é: ${code}`,'',
      'O código expira em 10 minutos e só pode ser usado uma vez.',
      'Este envio foi autorizado manualmente depois da confirmação do administrador.',
      'Se não pediu esta recuperação, ignore esta mensagem.','',
      'Jogos Lendários',
    ].join('\n')
    const payload=[
      `From: =?UTF-8?B?${base64Utf8('Jogos Lendários')}?= <${RECOVERY_EMAIL_FROM}>`,
      `To: <${to}>`,
      `Subject: =?UTF-8?B?${base64Utf8(subject)}?=`,
      `Date: ${new Date().toUTCString()}`,
      'MIME-Version: 1.0',
      'Content-Type: text/plain; charset=UTF-8',
      'Content-Transfer-Encoding: base64','',
      base64Utf8(body).replace(/(.{76})/g,'$1\r\n'),'.','',
    ].join('\r\n')
    await conn.write(new TextEncoder().encode(payload))
    const response=await smtpRead(conn)
    if(Number(response.slice(0,3))!==250)throw new Error('O Gmail não aceitou a mensagem.')
    await smtpCommand(conn,'QUIT',[221]).catch(()=>null)
  }finally{try{conn.close()}catch{}}
}
function newOtp(){
  const x=new Uint32Array(1);crypto.getRandomValues(x)
  return String(x[0]%1000000).padStart(6,'0')
}

Deno.serve(async(req)=>{
  if(req.method==='OPTIONS')return new Response('ok',{headers:CORS})
  try{
    const pathname=new URL(req.url).pathname
    let path=pathname
    for(const marker of ['/functions/v1/jogos-recovery','/jogos-recovery']){
      const i=pathname.indexOf(marker)
      if(i>=0){path=pathname.slice(i+marker.length)||'/';break}
    }
    if(req.method==='GET'&&path==='/health')return out({ok:true,from:RECOVERY_EMAIL_FROM,emailConfigured:Boolean(RECOVERY_EMAIL_APP_PASSWORD)})
    if(req.method==='POST'&&path==='/approve-send'){
      const auth=req.headers.get('authorization')??''
      const token=auth.startsWith('Bearer ')?auth.slice(7):''
      if(!token)return fail('Sessão administrativa inválida.',401)
      const body=await req.json().catch(()=>({}))
      const requestId=String((body as any).requestId||'')
      const code=newOtp()
      let prepared:any
      try{
        prepared=await rpc('jl_admin_prepare_recovery_send',{p_token:token,p_request_id:requestId,p_code:code})
        await sendRecoveryEmail(String(prepared.email),code)
        await rpc('jl_admin_mark_recovery_sent',{p_token:token,p_request_id:requestId})
      }catch(error){
        if(prepared?.request_id){
          await rpc('jl_admin_recovery_send_failed',{p_token:token,p_request_id:requestId}).catch(()=>null)
        }
        throw error
      }
      return out({ok:true,message:'Identidade confirmada. Código enviado por e-mail.',email:prepared.email})
    }
    return fail('Rota não encontrada.',404)
  }catch(error){
    console.error(error)
    return fail(String((error as Error)?.message||'Não foi possível enviar a recuperação.'),500)
  }
})