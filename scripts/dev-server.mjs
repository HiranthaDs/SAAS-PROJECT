import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });
const port = Number(process.env.PORT || 3000);
const root = join(process.cwd(), 'dist');
const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8' };
const respond = (res, status, data) => { res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }); res.end(JSON.stringify(data)); };
const allowedPermissions = ['salon_view','salon_create','salon_move','salon_approve','salon_allocate','customers_view','sales_view','settings_view'];
const cleanPermissions = value => Object.fromEntries(allowedPermissions.map(key => [key, value?.[key] === true]));
const readBody = async req => { let raw = ''; for await (const chunk of req) raw += chunk; return JSON.parse(raw || '{}'); };

async function requireSuperAdmin(req) {
  const token = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) throw Object.assign(new Error('Sign in is required.'), { status: 401 });
  const userResult = await admin.auth.getUser(token);
  if (userResult.error || !userResult.data.user) throw Object.assign(new Error('Your session is invalid or expired.'), { status: 401 });
  const profileResult = await admin.from('profiles').select('platform_role').eq('id', userResult.data.user.id).single();
  if (profileResult.error || profileResult.data?.platform_role !== 'super_admin') throw Object.assign(new Error('Only a super administrator can manage accounts.'), { status: 403 });
  return userResult.data.user;
}

async function auditAccountAction(orgId, actorId, action, userId, metadata = {}) {
  const result = await admin.from('activity_log').insert({ org_id: orgId, actor_id: actorId, action, entity_type: 'account', entity_id: userId, metadata });
  if (result.error) throw result.error;
}

async function createManagedAccount(req, res) {
  if (req.method !== 'POST') return respond(res, 405, { error: 'Method not allowed' });
  let actor; try { actor = await requireSuperAdmin(req); } catch (error) { return respond(res, error.status || 500, { error: error.message }); }
  let body; try { body = await readBody(req); } catch { return respond(res, 400, { error: 'Invalid request body' }); }
  const orgId = String(body.org_id || '');
  const locationId = String(body.location_id || '');
  const email = String(body.email || '').trim().toLowerCase();
  const password = String(body.password || '');
  const fullName = String(body.full_name || '').trim();
  const title = String(body.title || '').trim();
  const role = ['viewer','member','manager','admin'].includes(body.role) ? body.role : 'member';
  if (!/^[0-9a-f-]{36}$/i.test(orgId)) return respond(res, 400, { error: 'Choose a valid workspace.' });
  if (!/^[0-9a-f-]{36}$/i.test(locationId)) return respond(res, 400, { error: 'Choose a valid salon location.' });
  if (!/^\S+@\S+\.\S+$/.test(email)) return respond(res, 400, { error: 'Enter a valid email address.' });
  if (password.length < 10) return respond(res, 400, { error: 'Temporary password must contain at least 10 characters.' });
  if (!fullName) return respond(res, 400, { error: 'Full name is required.' });
  const orgResult = await admin.from('organizations').select('id,name').eq('id', orgId).maybeSingle();
  if (orgResult.error || !orgResult.data) return respond(res, 404, { error: 'Workspace not found.' });
  const locationResult = await admin.from('salon_locations').select('id,name,employee_login_slug').eq('id', locationId).eq('org_id', orgId).eq('active', true).maybeSingle();
  if (locationResult.error || !locationResult.data) return respond(res, 404, { error: 'Salon location not found or inactive.' });
  const created = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { full_name: fullName, company_name: `${fullName} setup` } });
  if (created.error) return respond(res, created.error.status === 422 ? 409 : (created.error.status || 400), { error: created.error.message });
  const userId = created.data.user.id;
  try {
    const autoMemberships = await admin.from('memberships').select('org_id').eq('user_id', userId);
    if (autoMemberships.error) throw autoMemberships.error;
    const autoOrgIds = (autoMemberships.data || []).map(item => item.org_id).filter(id => id !== orgId);
    if (autoOrgIds.length) { const removed = await admin.from('organizations').delete().in('id', autoOrgIds).eq('owner_id', userId); if (removed.error) throw removed.error; }
    const profile = await admin.from('profiles').update({ full_name: fullName, email, must_change_password: true }).eq('id', userId); if (profile.error) throw profile.error;
    const membership = await admin.from('memberships').upsert({ org_id: orgId, user_id: userId, role, status: 'active' }); if (membership.error) throw membership.error;
    const access = await admin.from('organization_user_access').upsert({ org_id: orgId, user_id: userId, location_id: locationId, title: title || null, permissions: cleanPermissions(body.permissions), created_by: actor.id }); if (access.error) throw access.error;
    const employee = await admin.from('employees').insert({ org_id: orgId, location_id: locationId, user_id: userId, name: fullName, email, role_title: title || 'Workspace user', department: 'Salon', employment_status: 'active', bookable_for_appointments: true }); if (employee.error) throw employee.error;
    await auditAccountAction(orgId, actor.id, 'account.created', userId, { account_email: email, full_name: fullName, role, title, location_id: locationId, location_name: locationResult.data.name });
    return respond(res, 201, { created: true, user_id: userId, location_id: locationId, employee_login_slug: locationResult.data.employee_login_slug });
  } catch (error) {
    await admin.from('employees').delete().eq('user_id', userId);
    await admin.auth.admin.deleteUser(userId).catch(() => {});
    return respond(res, 400, { error: error.message || 'Unable to provision the account.' });
  }
}

async function updateManagedAccount(req, res, userId) {
  if (req.method !== 'PATCH') return respond(res, 405, { error: 'Method not allowed' });
  let actor; try { actor = await requireSuperAdmin(req); } catch (error) { return respond(res, error.status || 500, { error: error.message }); }
  let body; try { body = await readBody(req); } catch { return respond(res, 400, { error: 'Invalid request body' }); }
  const orgId = String(body.org_id || '');
  const locationId = String(body.location_id || '');
  const membershipResult = await admin.from('memberships').select('user_id').eq('org_id', orgId).eq('user_id', userId).maybeSingle();
  if (membershipResult.error || !membershipResult.data) return respond(res, 404, { error: 'Workspace account not found.' });
  if (body.action === 'reset_password') {
    const password = String(body.password || ''); if (password.length < 10) return respond(res, 400, { error: 'Temporary password must contain at least 10 characters.' });
    const updated = await admin.auth.admin.updateUserById(userId, { password }); if (updated.error) return respond(res, updated.error.status || 400, { error: updated.error.message });
    const profile = await admin.from('profiles').update({ must_change_password: true }).eq('id', userId); if (profile.error) return respond(res, 400, { error: profile.error.message });
    await auditAccountAction(orgId, actor.id, 'account.temporary_password_reset', userId);
    return respond(res, 200, { updated: true });
  }
  if (!/^[0-9a-f-]{36}$/i.test(locationId)) return respond(res, 400, { error: 'Choose a valid salon location.' });
  const locationResult = await admin.from('salon_locations').select('id,name').eq('id', locationId).eq('org_id', orgId).eq('active', true).maybeSingle();
  if (locationResult.error || !locationResult.data) return respond(res, 404, { error: 'Salon location not found or inactive.' });
  const role = ['viewer','member','manager','admin'].includes(body.role) ? body.role : 'member';
  const status = ['active','suspended'].includes(body.status) ? body.status : 'active';
  if (actor.id === userId && status === 'suspended') return respond(res, 400, { error: 'You cannot suspend your own super-admin account.' });
  const membership = await admin.from('memberships').update({ role, status }).eq('org_id', orgId).eq('user_id', userId); if (membership.error) return respond(res, 400, { error: membership.error.message });
  const access = await admin.from('organization_user_access').upsert({ org_id: orgId, user_id: userId, location_id: locationId, title: String(body.title || '').trim() || null, permissions: cleanPermissions(body.permissions), created_by: actor.id }); if (access.error) return respond(res, 400, { error: access.error.message });
  const employee = await admin.from('employees').update({ location_id: locationId, role_title: String(body.title || '').trim() || 'Workspace user', employment_status: status === 'active' ? 'active' : 'inactive' }).eq('org_id', orgId).eq('user_id', userId); if (employee.error) return respond(res, 400, { error: employee.error.message });
  await auditAccountAction(orgId, actor.id, 'account.permissions_updated', userId, { role, status, title: body.title || '', location_id: locationId, location_name: locationResult.data.name, permissions: cleanPermissions(body.permissions) });
  return respond(res, 200, { updated: true });
}

createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname === '/api/admin/accounts') return createManagedAccount(req, res);
  const managedAccountMatch = url.pathname.match(/^\/api\/admin\/accounts\/([0-9a-f-]{36})$/i);
  if (managedAccountMatch) return updateManagedAccount(req, res, managedAccountMatch[1]);
  if (url.pathname === '/api/signup') {
    if (req.method !== 'POST') return respond(res, 405, { error: 'Method not allowed' });
    let raw = ''; for await (const chunk of req) raw += chunk;
    let body; try { body = JSON.parse(raw); } catch { return respond(res, 400, { error: 'Invalid request body' }); }
    const email = String(body.email || '').trim().toLowerCase();
    const password = String(body.password || '');
    const fullName = String(body.full_name || '').trim();
    const companyName = String(body.company_name || `${fullName}'s Workspace`).trim();
    if (!/^\S+@\S+\.\S+$/.test(email)) return respond(res, 400, { error: 'Enter a valid email address.' });
    if (password.length < 8) return respond(res, 400, { error: 'Password must contain at least 8 characters.' });
    if (!fullName) return respond(res, 400, { error: 'Your name is required.' });
    const created = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { full_name: fullName, company_name: companyName } });
    if (created.error) return respond(res, created.error.status === 422 ? 409 : (created.error.status || 400), { error: created.error.message });
    return respond(res, 201, { created: true, user_id: created.data.user.id });
  }
  const relative = url.pathname === '/' ? 'index.html' : url.pathname.replace(/^\/+/, '');
  const file = normalize(join(root, relative));
  if (!file.startsWith(normalize(root))) { res.writeHead(403); return res.end(); }
  try { const content = await readFile(file); res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream' }); res.end(content); }
  catch { const content = await readFile(join(root, 'index.html')); res.writeHead(200, { 'content-type': types['.html'] }); res.end(content); }
}).listen(port, '127.0.0.1', () => console.log(`Hich Solutions running at http://localhost:${port}`));
