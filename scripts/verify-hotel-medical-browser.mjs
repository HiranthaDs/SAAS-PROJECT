import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';
import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
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
const email = `hotel-medical-browser-${marker}@example.test`;
const password = `Browser-${crypto.randomUUID()}!`;
const browserDirectory = mkdtempSync(join(tmpdir(), 'hotel-medical-browser-'));
const debuggingPort = 9241;
let userId = '';
let orgId = '';
let chrome;
let socket;
let commandId = 0;
const pending = new Map();
const browserErrors = [];
const pause = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const required = (result, label) => { if (result.error) throw new Error(`${label}: ${result.error.message}`);return result.data; };

async function waitForJson(url, attempts = 80) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try { const response = await fetch(url);if (response.ok) return response.json(); } catch {}
    await pause(100);
  }
  throw new Error(`Timed out waiting for ${url}`);
}
function send(method, params = {}) {
  const id = ++commandId;socket.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}
async function evaluate(expression) {
  const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text || 'Browser evaluation failed');
  return result.result?.value;
}
async function waitFor(expression, label, attempts = 150) {
  for (let attempt = 0; attempt < attempts; attempt += 1) { if (await evaluate(`Boolean(${expression})`)) return;await pause(100); }
  const snapshot = await evaluate(`({url:location.href,body:document.body.innerText.slice(0,1200),auth:document.querySelector('#authError')?.textContent,marketingHidden:document.querySelector('#marketingSite')?.classList.contains('hidden'),authHidden:document.querySelector('#authShell')?.classList.contains('hidden'),appHidden:document.querySelector('#appShell')?.classList.contains('hidden'),storage:Object.keys(localStorage),errors:${JSON.stringify(browserErrors)}})`);
  throw new Error(`${label} timed out: ${JSON.stringify(snapshot)}`);
}
async function fillAndSubmit(formSelector, fields) {
  await evaluate(`(()=>{const form=document.querySelector(${JSON.stringify(formSelector)});const fields=${JSON.stringify(fields)};for(const [name,value] of Object.entries(fields)){const input=form.elements[name];input.value=value;input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}))}form.requestSubmit();return true})()`);
}
async function screenshot(name) {
  const image = await send('Page.captureScreenshot', { format: 'png', fromSurface: true, captureBeyondViewport: false });
  writeFileSync(`.chrome-qa/${name}.png`, Buffer.from(image.data, 'base64'));
}

try {
  const user = required(await admin.auth.admin.createUser({
    email, password, email_confirm: true,
    user_metadata: { full_name: 'Hotel Medical Browser Owner', company_name: `Browser Operations ${marker}`, provisioning_kind: 'workspace_owner' },
  }), 'Create browser owner').user;
  userId = user.id;
  orgId = required(await admin.from('memberships').select('org_id').eq('user_id', userId).single(), 'Load browser workspace').org_id;
  required(await admin.from('organizations').update({ name: `Harbour Hotel ${marker}`, business_type: 'hotel', industry: 'hotel' }).eq('id', orgId), 'Configure hotel workspace');
  required(await admin.from('organization_settings').update({ enabled_modules: ['overview', 'industry_ops', 'customers', 'inventory', 'finance', 'people'], preferences: { onboarding_completed: true, room_count: 5 } }).eq('org_id', orgId), 'Configure workspace modules');
  const location = required(await admin.from('salon_locations').select('id').eq('org_id', orgId).single(), 'Load hotel branch');
  required(await ownerClient.auth.signInWithPassword({ email, password }), 'Sign in browser owner');
  const property = required(await ownerClient.from('hotel_properties').insert({ org_id: orgId, location_id: location.id, name: `Harbour Hotel ${marker}`, public_slug: `browser-hotel-${marker}`, description: 'A calm coastal stay with live room availability.', address: '42 Ocean Road, Colombo', phone: '077 555 0101', amenities: ['Breakfast', 'Pool', 'Wi-Fi'], created_by: userId }).select('id,public_slug').single(), 'Create browser hotel');
  const rooms = required(await ownerClient.from('hotel_room_types').insert([
    { org_id: orgId, property_id: property.id, name: 'Ocean Deluxe', code: 'ODX', description: 'King room with ocean view and breakfast.', room_count: 5, max_adults: 2, max_children: 1, nightly_rate: 28500, includes: ['Breakfast', 'Wi-Fi', 'Pool'] },
    { org_id: orgId, property_id: property.id, name: 'Family Suite', code: 'FAM', description: 'Two-room suite for families.', room_count: 3, max_adults: 3, max_children: 2, nightly_rate: 42000, includes: ['Breakfast', 'Kitchenette'] },
  ]).select('id'), 'Create browser rooms');
  required(await ownerClient.rpc('create_hotel_booking', { p_property_id: property.id, p_room_type_id: rooms[0].id, p_guest_name: 'Browser Guest', p_whatsapp: '0771234567', p_email: null, p_arrival: '2099-05-10', p_departure: '2099-05-13', p_adults: 2, p_children: 0, p_rooms: 2, p_notes: 'Late arrival' }), 'Create browser booking');

  mkdirSync('.chrome-qa', { recursive: true });
  chrome = spawn(chromePath, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--window-size=1536,1050', `--remote-debugging-port=${debuggingPort}`, `--user-data-dir=${browserDirectory}`, 'about:blank'], { stdio: 'ignore', windowsHide: true });
  await waitForJson(`http://127.0.0.1:${debuggingPort}/json/version`);
  const targetResponse = await fetch(`http://127.0.0.1:${debuggingPort}/json/new?${encodeURIComponent(`${appUrl}/hotel/${property.public_slug}`)}`, { method: 'PUT' });
  const target = await targetResponse.json();socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true });socket.addEventListener('error', reject, { once: true }); });
  socket.addEventListener('message', (event) => { const message = JSON.parse(event.data);if (message.id && pending.has(message.id)) { const task = pending.get(message.id);pending.delete(message.id);message.error ? task.reject(new Error(message.error.message)) : task.resolve(message.result);return; }if (message.method === 'Runtime.exceptionThrown') browserErrors.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);if (message.method === 'Log.entryAdded' && message.params.entry.level === 'error') browserErrors.push(message.params.entry.text); });
  await send('Runtime.enable');await send('Log.enable');await send('Page.enable');
  await waitFor(`document.querySelectorAll('.public-hotel-room').length===2 && document.querySelector('[data-check-hotel]')`, 'Public hotel portal');
  const publicHotel = await evaluate(`({title:document.querySelector('.hotel-public-hero h1')?.textContent,rooms:document.querySelectorAll('.public-hotel-room').length,available:document.querySelector('.hotel-public-status')?.textContent,overflow:document.documentElement.scrollWidth>innerWidth+1})`);
  if (publicHotel.title !== `Harbour Hotel ${marker}` || publicHotel.rooms !== 2 || publicHotel.overflow) throw new Error(`Invalid public hotel portal: ${JSON.stringify(publicHotel)}`);
  await screenshot('hotel-public-desktop');
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });await pause(300);
  const hotelMobile = await evaluate(`({innerWidth,scrollWidth:document.documentElement.scrollWidth,roomWidth:document.querySelector('.public-hotel-room')?.getBoundingClientRect().width})`);
  if (hotelMobile.scrollWidth > hotelMobile.innerWidth + 1 || hotelMobile.roomWidth > hotelMobile.innerWidth) throw new Error(`Hotel mobile overflow: ${JSON.stringify(hotelMobile)}`);
  await screenshot('hotel-public-mobile');await send('Emulation.clearDeviceMetricsOverride');

  await send('Page.navigate', { url: `${appUrl}/?login=admin` });await waitFor(`document.querySelector('#signinForm') && !document.querySelector('#authShell')?.classList.contains('hidden')`, 'Hotel admin sign-in');
  await fillAndSubmit('#signinForm', { email, password });await waitFor(`!document.querySelector('#appShell')?.classList.contains('hidden')`, 'Hotel admin dashboard');
  await evaluate(`document.querySelector('#industryModuleNav')?.click()`);await waitFor(`document.querySelector('.hotel-matrix') && document.querySelectorAll('.hotel-room-card').length===2`, 'Hotel control center');
  const hotelAdmin = await evaluate(`({matrix:document.querySelectorAll('.hotel-inventory-cell').length,bookings:document.querySelectorAll('[data-hotel-invoice]').length,link:document.querySelector('.hotel-link-card input')?.value})`);
  if (hotelAdmin.matrix !== 28 || hotelAdmin.bookings !== 1 || !hotelAdmin.link.includes(property.public_slug)) throw new Error(`Invalid hotel admin dashboard: ${JSON.stringify(hotelAdmin)}`);
  await screenshot('hotel-admin-dashboard');

  required(await admin.from('organizations').update({ name: `Medical Center ${marker}`, business_type: 'healthcare_clinic', industry: 'healthcare_clinic' }).eq('id', orgId), 'Switch browser workspace to medical');
  const center = required(await ownerClient.from('medical_centers').insert({ org_id: orgId, location_id: location.id, name: `Medical Center ${marker}`, public_slug: `browser-medical-${marker}`, phone: '077 555 0202', address: '18 Health Avenue, Colombo', default_slot_minutes: 15, created_by: userId }).select('id,public_slug').single(), 'Create browser medical center');
  const doctors = required(await ownerClient.from('medical_doctors').insert([
    { org_id: orgId, center_id: center.id, name: 'Dr. Anika Perera', specialty: 'General medicine', room_label: 'Room 1', queue_prefix: 'A' },
    { org_id: orgId, center_id: center.id, name: 'Dr. Milan Silva', specialty: 'Paediatrics', room_label: 'Room 2', queue_prefix: 'B' },
  ]).select('id'), 'Create browser doctors');
  const dateParts = new Intl.DateTimeFormat('en', { timeZone: 'Asia/Colombo', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date());
  const date = Object.fromEntries(dateParts.map((part) => [part.type, part.value]));const sessionDate = `${date.year}-${date.month}-${date.day}`;
  required(await ownerClient.from('medical_sessions').insert(doctors.map((doctor) => ({ org_id: orgId, center_id: center.id, doctor_id: doctor.id, session_date: sessionDate, starts_at: '08:00', ends_at: '12:00', slot_minutes: 15, capacity: 16, status: 'open', created_by: userId }))), 'Create browser sessions');
  required(await ownerClient.rpc('issue_medical_queue_number', { p_slug: center.public_slug, p_patient_name: 'Browser Patient', p_whatsapp: '0777654321', p_session_id: null, p_source: 'staff' }), 'Issue browser patient');

  await send('Page.navigate', { url: `${appUrl}/?qa=${marker}#industry_ops` });await waitFor(`!document.querySelector('#appShell')?.classList.contains('hidden') && /Clinic|Medical/.test(document.querySelector('.workspace-switcher small')?.textContent||'')`, 'Medical admin workspace');
  await evaluate(`document.querySelector('#industryModuleNav')?.click()`);await waitFor(`document.querySelectorAll('.doctor-console').length===2 && document.querySelector('[data-medical-qr]')`, 'Medical queue dashboard');
  await evaluate(`document.querySelector('[data-medical-qr]')?.click()`);await waitFor(`document.querySelector('.qr-sheet img')?.src.startsWith('data:image/png')`, 'Medical queue QR');await screenshot('medical-admin-qr');await evaluate(`document.querySelector('[data-close-modal]')?.click()`);await screenshot('medical-admin-dashboard');
  await send('Page.navigate', { url: `${appUrl}/medical/${center.public_slug}` });await waitFor(`document.querySelectorAll('.medical-public-sessions article').length===2 && document.querySelector('#medicalPublicForm')`, 'Public medical portal');
  const publicMedical = await evaluate(`({sessions:document.querySelectorAll('.medical-public-sessions article').length,center:document.querySelector('.medical-public-hero h1')?.textContent,overflow:document.documentElement.scrollWidth>innerWidth+1})`);
  if (publicMedical.sessions !== 2 || publicMedical.center !== `Medical Center ${marker}` || publicMedical.overflow) throw new Error(`Invalid public medical portal: ${JSON.stringify(publicMedical)}`);
  await screenshot('medical-public-desktop');
  if (browserErrors.length) throw new Error(`Browser errors: ${browserErrors.join(' | ')}`);
  console.log(JSON.stringify({ publicHotel: true, hotelMobile: true, hotelAdmin: true, roomDateMatrixCells: 28, publicMedical: true, medicalAdmin: true, qrGenerated: true, browserErrors: 0 }));
} finally {
  try { socket?.close(); } catch {}
  try { chrome?.kill(); } catch {}
  await ownerClient.auth.signOut();
  if (orgId) await admin.from('organizations').delete().eq('id', orgId);
  if (userId) await admin.auth.admin.deleteUser(userId);
  try { rmSync(browserDirectory, { recursive: true, force: true }); } catch {}
}
