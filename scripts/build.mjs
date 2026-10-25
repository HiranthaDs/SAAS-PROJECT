import { build } from 'esbuild';
import { config } from 'dotenv';
import { mkdir, readFile, writeFile } from 'node:fs/promises';

config({ path: '.env.local' });

const publicUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const publicKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

if (!publicUrl || !publicKey) {
  throw new Error('Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY');
}

await build({
  entryPoints: ['dist/assets/app.js'],
  bundle: true,
  format: 'esm',
  minify: true,
  sourcemap: false,
  outfile: 'dist/assets/app.bundle.js',
  define: {
    'process.env.NEXT_PUBLIC_SUPABASE_URL': JSON.stringify(publicUrl),
    'process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY': JSON.stringify(publicKey),
  },
});

const [html, css, app] = await Promise.all([
  readFile('dist/index.html', 'utf8'),
  readFile('dist/assets/styles.css', 'utf8'),
  readFile('dist/assets/app.bundle.js', 'utf8'),
]);

const worker = `
const INDEX_HTML=${JSON.stringify(html)};
const STYLES=${JSON.stringify(css)};
const APP=${JSON.stringify(app)};
const json=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store'}});
async function createAccount(request,env){
  if(request.method!=='POST')return json({error:'Method not allowed'},405);
  let body;try{body=await request.json()}catch{return json({error:'Invalid request body'},400)}
  const email=String(body.email||'').trim().toLowerCase();
  const password=String(body.password||'');
  const fullName=String(body.full_name||'').trim();
  const companyName=String(body.company_name||(fullName+"'s Workspace")).trim();
  if(!/^\\S+@\\S+\\.\\S+$/.test(email))return json({error:'Enter a valid email address.'},400);
  if(password.length<8)return json({error:'Password must contain at least 8 characters.'},400);
  if(!fullName)return json({error:'Your name is required.'},400);
  if(!env.SUPABASE_URL||!env.SUPABASE_SECRET_KEY)return json({error:'Account service is not configured.'},503);
  const response=await fetch(env.SUPABASE_URL+'/auth/v1/admin/users',{method:'POST',headers:{'content-type':'application/json','apikey':env.SUPABASE_SECRET_KEY,'authorization':'Bearer '+env.SUPABASE_SECRET_KEY},body:JSON.stringify({email,password,email_confirm:true,user_metadata:{full_name:fullName,company_name:companyName}})});
  const result=await response.json().catch(()=>({}));
  if(!response.ok)return json({error:result.msg||result.message||result.error_description||'Unable to create account.'},response.status===422?409:response.status);
  return json({created:true,user_id:result.id},201);
}
export default {async fetch(request,env){
  const url=new URL(request.url);
  if(url.pathname==='/api/signup')return createAccount(request,env);
  if(url.pathname==='/assets/styles.css')return new Response(STYLES,{headers:{'content-type':'text/css; charset=utf-8','cache-control':'public, max-age=300'}});
  if(url.pathname==='/assets/app.bundle.js')return new Response(APP,{headers:{'content-type':'text/javascript; charset=utf-8','cache-control':'public, max-age=300'}});
  if(url.pathname==='/favicon.ico')return new Response(null,{status:204});
  return new Response(INDEX_HTML,{headers:{'content-type':'text/html; charset=utf-8','cache-control':'no-store'}});
}};
`;
await mkdir('dist/server', { recursive: true });
await writeFile('dist/server/index.js', worker);

