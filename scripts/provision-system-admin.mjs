import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });
const { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY } = process.env;
if (!SUPABASE_URL || !SUPABASE_PUBLISHABLE_KEY || !SUPABASE_SECRET_KEY) throw new Error('Missing Supabase administrator variables');

let raw = '';
for await (const chunk of process.stdin) raw += chunk;
const input = JSON.parse(raw || '{}');
const email = String(input.email || '').trim().toLowerCase();
const password = String(input.password || '');
const fullName = String(input.full_name || 'System Administrator').trim();
if (!/^\S+@\S+\.\S+$/.test(email) || password.length < 8) throw new Error('Valid email and password are required');

const admin = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const listed = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
if (listed.error) throw listed.error;
let user = listed.data.users.find((item) => item.email?.toLowerCase() === email);
if (!user) {
  const created = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name: fullName, company_name: 'HICH ONE System Administration', provisioning_kind: 'workspace_owner' },
  });
  if (created.error) throw created.error;
  user = created.data.user;
} else {
  const updated = await admin.auth.admin.updateUserById(user.id, { password, email_confirm: true, user_metadata: { ...user.user_metadata, full_name: fullName, provisioning_kind: 'workspace_owner' } });
  if (updated.error) throw updated.error;
}
const profile = await admin.from('profiles').upsert({ id: user.id, email, full_name: fullName, platform_role: 'system_admin', must_change_password: false }, { onConflict: 'id' });
if (profile.error) throw profile.error;

const browser = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const login = await browser.auth.signInWithPassword({ email, password });
if (login.error || !login.data.session) throw login.error || new Error('System administrator login verification failed');
const verifiedProfile = await browser.from('profiles').select('platform_role').eq('id', user.id).single();
if (verifiedProfile.error || verifiedProfile.data.platform_role !== 'system_admin') throw verifiedProfile.error || new Error('System administrator role verification failed');
const consoleAccess = await browser.rpc('get_system_admin_console');
if (consoleAccess.error) throw consoleAccess.error;
await browser.auth.signOut();
console.log(JSON.stringify({ provisioned: true, login_verified: true, console_verified: true, email, role: 'system_admin' }));
