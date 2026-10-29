import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });

const client = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const login = await client.auth.signInWithPassword({ email: process.env.SUPER_ADMIN_EMAIL, password: process.env.SUPER_ADMIN_PASSWORD });
if (login.error) throw login.error;

const industries = {
  clothing_fashion: 'fashion_operations', restaurant: 'restaurant_operations', hotel: 'hotel_operations',
  construction: 'construction_operations', real_estate: 'real_estate_operations', education: 'education_operations',
  healthcare_clinic: 'clinic_operations', logistics: 'logistics_operations',
  manufacturing_business: 'manufacturing_operations', agriculture: 'agriculture_operations',
};
const marker = crypto.randomUUID().slice(0, 8);
let orgId;

try {
  for (const [businessType, expectedKey] of Object.entries(industries)) {
    const [modules, moduleKey, locations] = await Promise.all([
      client.rpc('modules_for_business_type', { target_type: businessType }),
      client.rpc('industry_module_key', { target_type: businessType }),
      client.rpc('business_type_uses_locations', { target_type: businessType }),
    ]);
    if (modules.error || moduleKey.error || locations.error) throw modules.error || moduleKey.error || locations.error;
    if (!modules.data.includes('industry_ops') || moduleKey.data !== expectedKey || locations.data !== true) {
      throw new Error(`Invalid ${businessType} configuration`);
    }
  }

  const organization = await admin.from('organizations').insert({
    name: `Industry Verify ${marker}`, slug: `industry-verify-${marker}`, owner_id: login.data.user.id,
    industry: 'clothing_fashion', business_type: 'clothing_fashion', email: `industry-${marker}@example.test`,
  }).select('id').single();
  if (organization.error) throw organization.error;
  orgId = organization.data.id;

  const membership = await admin.from('memberships').insert({ org_id: orgId, user_id: login.data.user.id, role: 'owner', status: 'active' });
  if (membership.error) throw membership.error;
  const settings = await admin.from('organization_settings').insert({ org_id: orgId, currency: 'LKR', enabled_modules: ['overview', 'industry_ops'] });
  if (settings.error) throw settings.error;

  const locations = await client.from('salon_locations').select('id').eq('org_id', orgId);
  if (locations.error || locations.data.length !== 1) throw locations.error || new Error('A default location was not created for the new industry');

  const created = await client.from('module_records').insert({
    org_id: orgId, module_key: 'fashion_operations', record_type: 'style_order', title: 'Verification style',
    reference: `STYLE-${marker}`, status: 'design', data: { collection: 'Verification collection' }, created_by: login.data.user.id,
  }).select('id,status').single();
  if (created.error) throw created.error;

  const isolated = await client.from('module_records').insert({
    org_id: orgId, module_key: 'logistics_operations', record_type: 'shipment', title: 'Must be rejected', status: 'booked',
  });
  if (!isolated.error) throw new Error('Cross-industry record insertion was not rejected');

  const advanced = await client.rpc('advance_industry_record', { p_record_id: created.data.id });
  if (advanced.error || advanced.data !== 'sampling') throw advanced.error || new Error('Fashion workflow did not advance to sampling');
  const stored = await client.from('module_records').select('status').eq('id', created.data.id).single();
  if (stored.error || stored.data.status !== 'sampling') throw stored.error || new Error('Advanced workflow status was not stored');

  console.log(JSON.stringify({ industries: 10, modulesConfigured: true, defaultLocation: true, crossIndustryIsolation: true, workflowAdvance: 'design -> sampling' }));
} finally {
  if (orgId) await admin.from('organizations').delete().eq('id', orgId);
  await client.auth.signOut();
}
