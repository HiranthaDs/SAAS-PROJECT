import { readFile, readdir } from 'node:fs/promises';
import { config } from 'dotenv';
import pg from 'pg';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });

const { DATABASE_URL, SUPABASE_URL, SUPABASE_SECRET_KEY, SUPER_ADMIN_EMAIL, SUPER_ADMIN_PASSWORD } = process.env;
if (!DATABASE_URL || !SUPABASE_URL || !SUPABASE_SECRET_KEY) throw new Error('Missing Supabase setup environment variables');

const pool = new pg.Pool({ connectionString: DATABASE_URL, ssl: { rejectUnauthorized: false } });
const migrationsUrl = new URL('../supabase/migrations/', import.meta.url);
const migrations = (await readdir(migrationsUrl)).filter((name) => name.endsWith('.sql')).sort();
for (const migration of migrations) {
  const sql = await readFile(new URL(migration, migrationsUrl), 'utf8');
  await pool.query(sql);
}
await pool.end();

if (SUPER_ADMIN_EMAIL && SUPER_ADMIN_PASSWORD) {
  const admin = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, { auth: { autoRefreshToken: false, persistSession: false } });
  const listed = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
  if (listed.error) throw listed.error;
  let user = listed.data.users.find((item) => item.email?.toLowerCase() === SUPER_ADMIN_EMAIL.toLowerCase());
  if (!user) {
    const created = await admin.auth.admin.createUser({
      email: SUPER_ADMIN_EMAIL,
      password: SUPER_ADMIN_PASSWORD,
      email_confirm: true,
      user_metadata: { full_name: 'System Administrator', company_name: 'Hich Solutions' },
    });
    if (created.error) throw created.error;
    user = created.data.user;
  }
  const authUpdated = await admin.auth.admin.updateUserById(user.id, { password: SUPER_ADMIN_PASSWORD, email_confirm: true, user_metadata: { full_name: 'System Administrator', company_name: 'Hich Solutions' } });
  if (authUpdated.error) throw authUpdated.error;
  const profile = await admin.from('profiles').upsert({ id: user.id, email: SUPER_ADMIN_EMAIL, platform_role: 'super_admin', full_name: 'System Administrator' });
  if (profile.error) throw profile.error;
  let membership = await admin.from('memberships').select('org_id').eq('user_id', user.id).limit(1).maybeSingle();
  if (membership.error) throw membership.error;
  if (!membership.data) {
    const organization = await admin.from('organizations').insert({ name: 'Hich Solutions', slug: `hich-solutions-${user.id.slice(0, 6)}`, owner_id: user.id, email: SUPER_ADMIN_EMAIL }).select('id').single();
    if (organization.error) throw organization.error;
    const membershipCreated = await admin.from('memberships').insert({ org_id: organization.data.id, user_id: user.id, role: 'owner', status: 'active' }).select('org_id').single();
    if (membershipCreated.error) throw membershipCreated.error;
    const settingsCreated = await admin.from('organization_settings').insert({ org_id: organization.data.id });
    if (settingsCreated.error) throw settingsCreated.error;
    membership = membershipCreated;
  }
  const orgId = membership.data.org_id;
  const renamed = await admin.from('organizations').update({ name: 'Hich Solutions' }).eq('id', orgId);
  if (renamed.error) throw renamed.error;
  const existing = await admin.from('opportunities').select('id', { count: 'exact', head: true }).eq('org_id', orgId);
  if (existing.error) throw existing.error;
  if (!existing.count) {
    const sampleData = await Promise.all([
      admin.from('opportunities').insert([
        { org_id: orgId, company: 'Northstar Labs', title: 'Team analytics rollout', value: 24000, probability: 20, stage: 'New', owner_id: user.id },
        { org_id: orgId, company: 'Monocle Foods', title: 'Multi-site inventory', value: 41000, probability: 45, stage: 'Qualified', owner_id: user.id },
        { org_id: orgId, company: 'Kite Logistics', title: 'Warehouse automation', value: 56000, probability: 75, stage: 'Proposal', owner_id: user.id },
        { org_id: orgId, company: 'Field Notes', title: 'Service desk launch', value: 21500, probability: 100, stage: 'Won', owner_id: user.id },
      ]),
      admin.from('invoices').insert([
        { org_id: orgId, number: 'INV-2026-0482', customer: 'Northstar Labs', issue_date: '2026-10-24', subtotal: 12840, status: 'Paid', created_by: user.id },
        { org_id: orgId, number: 'INV-2026-0481', customer: 'Kite Logistics', issue_date: '2026-10-23', subtotal: 8750, status: 'Pending', created_by: user.id },
        { org_id: orgId, number: 'INV-2026-0479', customer: 'Studio Kind', issue_date: '2026-10-21', subtotal: 4920, status: 'Overdue', created_by: user.id },
      ]),
      admin.from('products').insert([
        { org_id: orgId, sku: 'NX-1001', name: 'Ergo Task Chair', category: 'Furniture', stock: 128, forecast: 161, reorder_level: 20, price: 349 },
        { org_id: orgId, sku: 'NX-1002', name: 'Walnut Standing Desk', category: 'Furniture', stock: 14, forecast: 8, reorder_level: 20, price: 799 },
        { org_id: orgId, sku: 'NX-2004', name: 'Studio Lamp', category: 'Lighting', stock: 67, forecast: 72, reorder_level: 15, price: 129 },
        { org_id: orgId, sku: 'NX-3012', name: 'Acoustic Panel Set', category: 'Workspace', stock: 8, forecast: 4, reorder_level: 20, price: 245 },
      ]),
      admin.from('employees').insert([
        { org_id: orgId, user_id: user.id, name: 'System Administrator', email: SUPER_ADMIN_EMAIL, role_title: 'Platform Administrator', department: 'Leadership' },
        { org_id: orgId, name: 'Maya Khan', role_title: 'Sales Lead', department: 'Revenue' },
        { org_id: orgId, name: 'Sam Lee', role_title: 'Product Designer', department: 'Product' },
        { org_id: orgId, name: 'Noah Williams', role_title: 'Finance Manager', department: 'Finance' },
      ]),
      admin.from('projects').insert([
        { org_id: orgId, name: 'Commerce redesign', client: 'Atlas Studio', due_date: '2026-11-14', progress: 74, status: 'On track', manager_id: user.id },
        { org_id: orgId, name: 'Warehouse migration', client: 'Kite Logistics', due_date: '2026-11-28', progress: 48, status: 'At risk', manager_id: user.id },
      ]),
    ]);
    const sampleError = sampleData.find((result) => result.error)?.error;
    if (sampleError) throw sampleError;
  }
}

console.log('Supabase schema and administrator setup completed.');
