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
const permissionKeys=['salon_view','salon_create','salon_move','salon_approve','salon_allocate','customers_view','sales_view','settings_view'];
const cleanPermissions=value=>Object.fromEntries(permissionKeys.map(key=>[key,value&&value[key]===true]));
const serviceHeaders=env=>({'content-type':'application/json','apikey':env.SUPABASE_SECRET_KEY,'authorization':'Bearer '+env.SUPABASE_SECRET_KEY});
async function serviceCall(env,path,options={}){
  const response=await fetch(env.SUPABASE_URL+path,{...options,headers:{...serviceHeaders(env),...(options.headers||{})}});
  const result=await response.json().catch(()=>null);
  if(!response.ok){const error=new Error(result?.msg||result?.message||result?.error_description||result?.details||'Account service request failed.');error.status=response.status;throw error}
  return result;
}
async function requireSuperAdmin(request,env){
  if(!env.SUPABASE_URL||!env.SUPABASE_SECRET_KEY){const error=new Error('Account service is not configured.');error.status=503;throw error}
  const token=String(request.headers.get('authorization')||'').replace(/^Bearer\\s+/i,'');
  if(!token){const error=new Error('Sign in is required.');error.status=401;throw error}
  const response=await fetch(env.SUPABASE_URL+'/auth/v1/user',{headers:{'apikey':env.SUPABASE_SECRET_KEY,'authorization':'Bearer '+token}});
  const user=await response.json().catch(()=>null);
  if(!response.ok||!user?.id){const error=new Error('Your session is invalid or expired.');error.status=401;throw error}
  const profiles=await serviceCall(env,'/rest/v1/profiles?id=eq.'+encodeURIComponent(user.id)+'&select=platform_role');
  if(profiles?.[0]?.platform_role!=='super_admin'){const error=new Error('Only a super administrator can manage accounts.');error.status=403;throw error}
  return user;
}
async function auditAccount(env,orgId,actorId,action,userId,metadata={}){
  await serviceCall(env,'/rest/v1/activity_log',{method:'POST',headers:{'Prefer':'return=minimal'},body:JSON.stringify({org_id:orgId,actor_id:actorId,action,entity_type:'account',entity_id:userId,metadata})});
}
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
async function createManagedAccount(request,env){
  if(request.method!=='POST')return json({error:'Method not allowed'},405);
  let actor;try{actor=await requireSuperAdmin(request,env)}catch(error){return json({error:error.message},error.status||500)}
  let body;try{body=await request.json()}catch{return json({error:'Invalid request body'},400)}
  const orgId=String(body.org_id||'');const email=String(body.email||'').trim().toLowerCase();const password=String(body.password||'');const fullName=String(body.full_name||'').trim();const title=String(body.title||'').trim();const role=['viewer','member','manager','admin'].includes(body.role)?body.role:'member';
  if(!/^[0-9a-f-]{36}$/i.test(orgId))return json({error:'Choose a valid workspace.'},400);
  if(!/^\\S+@\\S+\\.\\S+$/.test(email))return json({error:'Enter a valid email address.'},400);
  if(password.length<10)return json({error:'Temporary password must contain at least 10 characters.'},400);
  if(!fullName)return json({error:'Full name is required.'},400);
  try{const org=await serviceCall(env,'/rest/v1/organizations?id=eq.'+encodeURIComponent(orgId)+'&select=id,name');if(!org?.length)return json({error:'Workspace not found.'},404)}catch(error){return json({error:error.message},error.status||400)}
  let userId='';
  try{
    const created=await serviceCall(env,'/auth/v1/admin/users',{method:'POST',body:JSON.stringify({email,password,email_confirm:true,user_metadata:{full_name:fullName,company_name:fullName+' setup'}})});userId=created.id;
    const autoMemberships=await serviceCall(env,'/rest/v1/memberships?user_id=eq.'+encodeURIComponent(userId)+'&select=org_id');
    for(const membership of autoMemberships||[]){if(membership.org_id!==orgId)await serviceCall(env,'/rest/v1/organizations?id=eq.'+encodeURIComponent(membership.org_id)+'&owner_id=eq.'+encodeURIComponent(userId),{method:'DELETE',headers:{'Prefer':'return=minimal'}})}
    await serviceCall(env,'/rest/v1/profiles?id=eq.'+encodeURIComponent(userId),{method:'PATCH',headers:{'Prefer':'return=minimal'},body:JSON.stringify({full_name:fullName,email,must_change_password:true})});
    await serviceCall(env,'/rest/v1/memberships?on_conflict=org_id,user_id',{method:'POST',headers:{'Prefer':'resolution=merge-duplicates,return=minimal'},body:JSON.stringify({org_id:orgId,user_id:userId,role,status:'active'})});
    await serviceCall(env,'/rest/v1/organization_user_access?on_conflict=org_id,user_id',{method:'POST',headers:{'Prefer':'resolution=merge-duplicates,return=minimal'},body:JSON.stringify({org_id:orgId,user_id:userId,title:title||null,permissions:cleanPermissions(body.permissions),created_by:actor.id})});
    await serviceCall(env,'/rest/v1/employees',{method:'POST',headers:{'Prefer':'return=minimal'},body:JSON.stringify({org_id:orgId,user_id:userId,name:fullName,email,role_title:title||'Workspace user',department:'Salon',employment_status:'active'})});
    await auditAccount(env,orgId,actor.id,'account.created',userId,{account_email:email,full_name:fullName,role,title});
    return json({created:true,user_id:userId},201);
  }catch(error){if(userId){await serviceCall(env,'/rest/v1/employees?user_id=eq.'+encodeURIComponent(userId),{method:'DELETE',headers:{'Prefer':'return=minimal'}}).catch(()=>{});await serviceCall(env,'/auth/v1/admin/users/'+encodeURIComponent(userId),{method:'DELETE'}).catch(()=>{})}return json({error:error.message},error.status===422?409:(error.status||400))}
}
async function updateManagedAccount(request,env,userId){
  if(request.method!=='PATCH')return json({error:'Method not allowed'},405);
  let actor;try{actor=await requireSuperAdmin(request,env)}catch(error){return json({error:error.message},error.status||500)}
  let body;try{body=await request.json()}catch{return json({error:'Invalid request body'},400)}
  const orgId=String(body.org_id||'');
  try{
    const membership=await serviceCall(env,'/rest/v1/memberships?org_id=eq.'+encodeURIComponent(orgId)+'&user_id=eq.'+encodeURIComponent(userId)+'&select=user_id');if(!membership?.length)return json({error:'Workspace account not found.'},404);
    if(body.action==='reset_password'){
      const password=String(body.password||'');if(password.length<10)return json({error:'Temporary password must contain at least 10 characters.'},400);
      await serviceCall(env,'/auth/v1/admin/users/'+encodeURIComponent(userId),{method:'PUT',body:JSON.stringify({password})});
      await serviceCall(env,'/rest/v1/profiles?id=eq.'+encodeURIComponent(userId),{method:'PATCH',headers:{'Prefer':'return=minimal'},body:JSON.stringify({must_change_password:true})});
      await auditAccount(env,orgId,actor.id,'account.temporary_password_reset',userId);return json({updated:true});
    }
    const role=['viewer','member','manager','admin'].includes(body.role)?body.role:'member';const status=['active','suspended'].includes(body.status)?body.status:'active';
    if(actor.id===userId&&status==='suspended')return json({error:'You cannot suspend your own super-admin account.'},400);
    await serviceCall(env,'/rest/v1/memberships?org_id=eq.'+encodeURIComponent(orgId)+'&user_id=eq.'+encodeURIComponent(userId),{method:'PATCH',headers:{'Prefer':'return=minimal'},body:JSON.stringify({role,status})});
    await serviceCall(env,'/rest/v1/organization_user_access?on_conflict=org_id,user_id',{method:'POST',headers:{'Prefer':'resolution=merge-duplicates,return=minimal'},body:JSON.stringify({org_id:orgId,user_id:userId,title:String(body.title||'').trim()||null,permissions:cleanPermissions(body.permissions),created_by:actor.id})});
    await auditAccount(env,orgId,actor.id,'account.permissions_updated',userId,{role,status,title:body.title||'',permissions:cleanPermissions(body.permissions)});return json({updated:true});
  }catch(error){return json({error:error.message},error.status||400)}
}
export default {async fetch(request,env){
  const url=new URL(request.url);
  if(url.pathname==='/api/signup')return createAccount(request,env);
  if(url.pathname==='/api/admin/accounts')return createManagedAccount(request,env);
  const accountMatch=url.pathname.match(/^\\/api\\/admin\\/accounts\\/([0-9a-f-]{36})$/i);
  if(accountMatch)return updateManagedAccount(request,env,accountMatch[1]);
  if(url.pathname==='/assets/styles.css')return new Response(STYLES,{headers:{'content-type':'text/css; charset=utf-8','cache-control':'public, max-age=300'}});
  if(url.pathname==='/assets/app.bundle.js')return new Response(APP,{headers:{'content-type':'text/javascript; charset=utf-8','cache-control':'public, max-age=300'}});
  if(url.pathname==='/favicon.ico')return new Response(null,{status:204});
  return new Response(INDEX_HTML,{headers:{'content-type':'text/html; charset=utf-8','cache-control':'no-store'}});
}};
`;
await mkdir('dist/server', { recursive: true });
await writeFile('dist/server/index.js', worker);

