import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

config({ path: '.env.local' });
const { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY } = process.env;
const appUrl = String(process.env.APP_URL || 'http://127.0.0.1:3000').replace(/\/$/, '');
const chromePath = process.env.CHROME_PATH || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
if (!SUPABASE_URL || !SUPABASE_PUBLISHABLE_KEY || !SUPABASE_SECRET_KEY) throw new Error('Missing Supabase verification variables');

const admin = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const ownerClient = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const marker = crypto.randomUUID().slice(0, 8);
const ownerEmail = `browser-owner-${marker}@example.test`;
const employeeEmail = `browser-employee-${marker}@example.test`;
const ownerPassword = `Owner-${crypto.randomUUID()}!`;
const temporaryPassword = `Employee-${crypto.randomUUID()}!`;
const privatePassword = `Private-${crypto.randomUUID()}!`;
const browserDirectory = mkdtempSync(join(tmpdir(), 'hich-login-browser-'));
const debuggingPort = 9237;
let ownerId = '';
let employeeId = '';
let orgId = '';
let chrome;
let socket;
let commandId = 0;
const pending = new Map();
const browserErrors = [];

const required = (result, label) => {
  if (result.error) throw new Error(`${label}: ${result.error.message}`);
  return result.data;
};
const pause = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function waitForJson(url, attempts = 60) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      const response = await fetch(url);
      if (response.ok) return response.json();
    } catch {}
    await pause(100);
  }
  throw new Error(`Timed out waiting for ${url}`);
}

function send(method, params = {}) {
  const id = ++commandId;
  socket.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

async function evaluate(expression) {
  const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text || 'Browser evaluation failed');
  return result.result?.value;
}

async function waitFor(expression, label, attempts = 120) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (await evaluate(`Boolean(${expression})`)) return;
    await pause(100);
  }
  const snapshot = await evaluate(`({url:location.href,authError:document.querySelector('#authError')?.textContent,employeeError:document.querySelector('.employee-login-error')?.textContent,body:document.body.innerText.slice(0,1000)})`);
  throw new Error(`${label} timed out: ${JSON.stringify(snapshot)}`);
}

async function fillAndSubmit(formSelector, fields) {
  const payload = JSON.stringify(fields);
  await evaluate(`(()=>{const form=document.querySelector(${JSON.stringify(formSelector)});if(!form)throw new Error('Form not found: ${formSelector}');const fields=${payload};for(const [name,value] of Object.entries(fields)){const input=form.elements[name];if(!input)throw new Error('Input not found: '+name);input.value=value;input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}))}form.requestSubmit();return true})()`);
}

try {
  const owner = required(await admin.auth.admin.createUser({
    email: ownerEmail,
    password: ownerPassword,
    email_confirm: true,
    user_metadata: { full_name: 'Browser Test Owner', company_name: `Browser Login ${marker}`, provisioning_kind: 'workspace_owner' },
  }), 'Create browser-test owner').user;
  ownerId = owner.id;
  orgId = required(await admin.from('memberships').select('org_id').eq('user_id', ownerId).single(), 'Load browser-test workspace').org_id;
  required(await admin.from('organizations').update({ name: `Browser Salon ${marker}`, business_type: 'salon', industry: 'salon' }).eq('id', orgId), 'Activate browser-test salon');
  required(await admin.from('organization_settings').update({ enabled_modules: ['overview', 'salon', 'service_catalog', 'reminders', 'pos', 'sales_history', 'customers', 'inventory', 'finance', 'people'], preferences: { onboarding_completed: true, opening_time: '09:00', closing_time: '19:00', booking_interval: 30 } }).eq('org_id', orgId), 'Configure browser-test salon');
  const ownerLogin = required(await ownerClient.auth.signInWithPassword({ email: ownerEmail, password: ownerPassword }), 'Sign in browser-test owner');
  const branch = required(await ownerClient.rpc('create_salon_location', { p_org_id: orgId, p_name: `Browser Branch ${marker}`, p_code: 'WEB', p_city: 'Negombo', p_address: 'Negombo', p_phone: '', p_is_primary: false }), 'Create browser-test branch');
  const response = await fetch(`${appUrl}/api/admin/accounts`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${ownerLogin.session.access_token}` },
    body: JSON.stringify({
      org_id: orgId,
      location_id: branch.id,
      full_name: 'Browser Branch Employee',
      email: employeeEmail,
      password: temporaryPassword,
      title: 'Branch Manager',
      role: 'manager',
      permissions: { salon_view: true, salon_create: true, salon_move: true, salon_approve: true, salon_allocate: true, customers_view: true, sales_view: true, settings_view: true },
    }),
  });
  const account = await response.json();
  if (!response.ok) throw new Error(`Create browser-test branch account: ${account.error || response.statusText}`);
  employeeId = account.user_id;

  chrome = spawn(chromePath, [
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--no-default-browser-check',
    `--remote-debugging-port=${debuggingPort}`,
    `--user-data-dir=${browserDirectory}`,
    'about:blank',
  ], { stdio: 'ignore', windowsHide: true });
  await waitForJson(`http://127.0.0.1:${debuggingPort}/json/version`);
  const targetResponse = await fetch(`http://127.0.0.1:${debuggingPort}/json/new?${encodeURIComponent(`${appUrl}/staff/${branch.employee_login_slug}`)}`, { method: 'PUT' });
  if (!targetResponse.ok) throw new Error(`Unable to open browser target: ${targetResponse.status}`);
  const target = await targetResponse.json();
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true });socket.addEventListener('error', reject, { once: true }); });
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const task = pending.get(message.id);pending.delete(message.id);message.error ? task.reject(new Error(message.error.message)) : task.resolve(message.result);return;
    }
    if (message.method === 'Runtime.exceptionThrown') browserErrors.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
    if (message.method === 'Log.entryAdded' && message.params.entry.level === 'error') browserErrors.push(message.params.entry.text);
  });
  await send('Runtime.enable');
  await send('Log.enable');
  await send('Page.enable');

  await waitFor(`document.querySelector('#employeeLoginForm')`, 'Branch login form');
  await fillAndSubmit('#employeeLoginForm', { email: employeeEmail, password: temporaryPassword });
  await waitFor(`document.querySelector('#requiredPasswordForm') || (!document.querySelector('#appShell')?.classList.contains('hidden') && document.querySelector('#pageContent'))`, 'Branch workspace or required-password form');
  if (await evaluate(`Boolean(document.querySelector('#requiredPasswordForm'))`)) {
    await fillAndSubmit('#requiredPasswordForm', { password: privatePassword, confirm_password: privatePassword });
    await waitFor(`!document.querySelector('#modalLayer')?.classList.contains('open') && !document.querySelector('#appShell')?.classList.contains('hidden')`, 'Completed branch first-login password');
  }
  const branchIdentity = await evaluate(`({workspace:document.querySelector('.workspace-switcher strong')?.textContent,user:document.querySelector('.user-copy strong')?.textContent,role:document.querySelector('.user-copy small')?.textContent})`);
  if (branchIdentity.workspace !== `Browser Salon ${marker}` || !/manager|member/i.test(branchIdentity.role || '')) throw new Error(`Incorrect branch UI identity: ${JSON.stringify(branchIdentity)}`);

  await evaluate(`location.href='/?login=admin'`);
  await waitFor(`document.querySelector('#signinForm') && !document.querySelector('#authShell')?.classList.contains('hidden')`, 'Main login for assigned manager');
  await fillAndSubmit('#signinForm', { email: employeeEmail, password: privatePassword });
  await waitFor(`!document.querySelector('#appShell')?.classList.contains('hidden') && /manager/i.test(document.querySelector('.user-copy small')?.textContent||'')`, 'Assigned manager through main login');

  await evaluate(`location.href='/?login=admin'`);
  await waitFor(`document.querySelector('#signinForm') && !document.querySelector('#authShell')?.classList.contains('hidden')`, 'Normal administrator login');
  await fillAndSubmit('#signinForm', { email: ownerEmail, password: ownerPassword });
  await waitFor(`!document.querySelector('#appShell')?.classList.contains('hidden') && /Workspace super admin/.test(document.querySelector('.user-copy small')?.textContent||'')`, 'Workspace administrator dashboard');
  const adminIdentity = await evaluate(`({workspace:document.querySelector('.workspace-switcher strong')?.textContent,user:document.querySelector('.user-copy strong')?.textContent,role:document.querySelector('.user-copy small')?.textContent,authError:document.querySelector('#authError')?.textContent})`);
  if (adminIdentity.workspace !== `Browser Salon ${marker}`) throw new Error(`Incorrect administrator UI identity: ${JSON.stringify(adminIdentity)}`);

  await evaluate(`location.href=${JSON.stringify(`${appUrl}/staff/${branch.employee_login_slug}`)}`);
  await waitFor(`!document.querySelector('#appShell')?.classList.contains('hidden') && /Workspace super admin/.test(document.querySelector('.user-copy small')?.textContent||'')`, 'Administrator through branch location login');
  const adminBranchIdentity = await evaluate(`({workspace:document.querySelector('.workspace-switcher strong')?.textContent,role:document.querySelector('.user-copy small')?.textContent,portalError:document.querySelector('.employee-login-error')?.textContent})`);
  if (adminBranchIdentity.workspace !== `Browser Salon ${marker}` || adminBranchIdentity.portalError) throw new Error(`Incorrect administrator branch login: ${JSON.stringify(adminBranchIdentity)}`);
  if (browserErrors.length) throw new Error(`Browser errors: ${browserErrors.join(' | ')}`);

  console.log(JSON.stringify({
    browserBranchLogin: true,
    browserFirstPasswordChange: true,
    browserBranchWorkspaceLoaded: true,
    browserManagerMainLogin: true,
    browserAdminSwitch: true,
    browserAdminBranchLogin: true,
    uncaughtBrowserErrors: 0,
  }));
} finally {
  try { socket?.close(); } catch {}
  try { chrome?.kill(); } catch {}
  await ownerClient.auth.signOut();
  if (orgId) await admin.from('organizations').delete().eq('id', orgId);
  if (employeeId) await admin.auth.admin.deleteUser(employeeId);
  if (ownerId) await admin.auth.admin.deleteUser(ownerId);
  try { rmSync(browserDirectory, { recursive: true, force: true }); } catch {}
}
