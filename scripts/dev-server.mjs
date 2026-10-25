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

createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
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
