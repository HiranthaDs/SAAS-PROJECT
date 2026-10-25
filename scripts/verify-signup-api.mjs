import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });

const email = `hich-api-${Date.now()}@outlook.com`;
const password = `Api-${crypto.randomUUID()}!`;
const browser = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
let userId;

try {
  const response = await fetch('http://127.0.0.1:3000/api/signup', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email, password, full_name: 'API Signup Test' })
  });
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || 'Signup API failed');

  const login = await browser.auth.signInWithPassword({ email, password });
  if (login.error || !login.data.session) throw login.error || new Error('Immediate password login failed');
  userId = login.data.user.id;

  const initialMembership = await browser.from('memberships').select('org_id,role,organizations(name,business_type)').eq('user_id', userId).single();
  if (initialMembership.error) throw initialMembership.error;
  const orgId = initialMembership.data.org_id;
  const initialSettings = await browser.from('organization_settings').select('enabled_modules,preferences').eq('org_id', orgId).single();
  if (initialSettings.error) throw initialSettings.error;
  const accountFirst = initialMembership.data.organizations.business_type === 'unconfigured'
    && initialSettings.data.enabled_modules.length === 0
    && initialSettings.data.preferences.onboarding_completed === false;
  if (!accountFirst) throw new Error('New account was configured before first-login onboarding');

  const configured = await browser.rpc('configure_business', {
    p_org_id: orgId,
    p_business_type: 'pharmacy',
    p_company_name: 'API Test Pharmacy',
    p_legal_name: 'API Test Pharmacy (Pvt) Ltd',
    p_phone: '+94 11 234 5678',
    p_email: email,
    p_address: 'Colombo, Sri Lanka',
    p_registration_number: 'PV-TEST-001',
    p_tax_number: 'VAT-TEST-001',
    p_branch_count: 2,
    p_employee_count: 12,
    p_preferences: { expiry_warning_days: 90, pharmacist_verification: true }
  });
  if (configured.error) throw configured.error;

  const finalMembership = await browser.from('memberships').select('org_id,role,organizations(name,legal_name,business_type,branch_count,employee_count)').eq('user_id', userId).single();
  if (finalMembership.error) throw finalMembership.error;
  const finalSettings = await browser.from('organization_settings').select('enabled_modules,preferences').eq('org_id', orgId).single();
  if (finalSettings.error) throw finalSettings.error;
  const modules = finalSettings.data.enabled_modules;
  const firstLoginConfiguration = finalMembership.data.organizations.name === 'API Test Pharmacy'
    && finalMembership.data.organizations.business_type === 'pharmacy'
    && finalMembership.data.organizations.branch_count === 2
    && modules.includes('pharmacy')
    && modules.includes('sales_history')
    && finalSettings.data.preferences.onboarding_completed === true;
  if (!firstLoginConfiguration) throw new Error('First-login business configuration was not persisted correctly');

  console.log(JSON.stringify({ instantSignupWithoutOtp: true, immediateLogin: true, accountFirst, firstLoginConfiguration, businessType: finalMembership.data.organizations.business_type, enabledModules: modules, role: finalMembership.data.role }));
} finally {
  await browser.auth.signOut();
  if (userId) {
    const deleted = await admin.auth.admin.deleteUser(userId);
    if (deleted.error) console.error(`Cleanup warning: ${deleted.error.message}`);
  }
}
