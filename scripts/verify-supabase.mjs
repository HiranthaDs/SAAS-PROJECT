import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });
const client = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const signedIn = await client.auth.signInWithPassword({ email: process.env.SUPER_ADMIN_EMAIL, password: process.env.SUPER_ADMIN_PASSWORD });
if (signedIn.error) throw signedIn.error;

const membership = await client.from('memberships').select('org_id,role,organizations(name)').eq('user_id', signedIn.data.user.id).single();
if (membership.error) throw membership.error;
const orgId = membership.data.org_id;
const results = await Promise.all([
  client.from('opportunities').select('id', { count: 'exact', head: true }).eq('org_id', orgId),
  client.from('invoices').select('id', { count: 'exact', head: true }).eq('org_id', orgId),
  client.from('products').select('id', { count: 'exact', head: true }).eq('org_id', orgId),
  client.from('employees').select('id', { count: 'exact', head: true }).eq('org_id', orgId),
  client.from('projects').select('id', { count: 'exact', head: true }).eq('org_id', orgId),
]);
const error = results.find((result) => result.error)?.error;
if (error) throw error;
await client.auth.signOut();

const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const testEmail = `nexora-test-${Date.now()}@example.test`;
const testUser = await admin.auth.admin.createUser({ email: testEmail, password: `Verify-${crypto.randomUUID()}!`, email_confirm: true, user_metadata: { full_name: 'Provisioning Test', company_name: 'Provisioning Test Co' } });
if (testUser.error) throw testUser.error;
const testMembership = await admin.from('memberships').select('org_id,role').eq('user_id', testUser.data.user.id).single();
if (testMembership.error) throw testMembership.error;
const deleted = await admin.auth.admin.deleteUser(testUser.data.user.id);
if (deleted.error) throw deleted.error;
console.log(JSON.stringify({
  authenticated: true,
  signupProvisioning: testMembership.data.role === 'owner',
  workspace: membership.data.organizations.name,
  role: membership.data.role,
  records: {
    opportunities: results[0].count,
    invoices: results[1].count,
    products: results[2].count,
    employees: results[3].count,
    projects: results[4].count,
  },
}));
