import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });
const { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY } = process.env;
const appUrl = String(process.env.APP_URL || 'http://127.0.0.1:3000').replace(/\/$/, '');
if (!SUPABASE_URL || !SUPABASE_PUBLISHABLE_KEY || !SUPABASE_SECRET_KEY) throw new Error('Missing Supabase verification variables');

const options = { auth: { persistSession: false, autoRefreshToken: false } };
const admin = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, options);
const ownerClient = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, options);
const sharedLoginClient = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, options);
const marker = crypto.randomUUID().slice(0, 8);
const ownerPassword = `Owner-${crypto.randomUUID()}!`;
const employeePassword = `Employee-${crypto.randomUUID()}!`;
let ownerId = '';
let employeeId = '';
let orgId = '';
let legacyOrgId = '';

const required = (result, label) => {
  if (result.error) throw new Error(`${label}: ${result.error.message}`);
  return result.data;
};

try {
  const ownerEmail = `login-owner-${marker}@example.test`;
  const employeeEmail = `login-employee-${marker}@example.test`;
  const owner = required(await admin.auth.admin.createUser({
    email: ownerEmail,
    password: ownerPassword,
    email_confirm: true,
    user_metadata: { full_name: 'Login Test Owner', company_name: `Login Test ${marker}`, provisioning_kind: 'workspace_owner' },
  }), 'Create workspace owner').user;
  ownerId = owner.id;
  orgId = required(await admin.from('memberships').select('org_id').eq('user_id', ownerId).single(), 'Load workspace').org_id;
  required(await admin.from('organizations').update({ business_type: 'salon', industry: 'salon', name: `Login Salon ${marker}` }).eq('id', orgId), 'Activate salon');
  required(await admin.from('organization_settings').update({ preferences: { onboarding_completed: true, opening_time: '09:00', closing_time: '19:00', booking_interval: 30 } }).eq('org_id', orgId), 'Complete onboarding');

  const ownerLogin = required(await ownerClient.auth.signInWithPassword({ email: ownerEmail, password: ownerPassword }), 'Sign in workspace owner');
  const branch = required(await ownerClient.rpc('create_salon_location', {
    p_org_id: orgId,
    p_name: `Negombo Login Branch ${marker}`,
    p_code: 'NEG',
    p_city: 'Negombo',
    p_address: 'Negombo',
    p_phone: '',
    p_is_primary: false,
  }), 'Create branch');

  const accountResponse = await fetch(`${appUrl}/api/admin/accounts`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${ownerLogin.session.access_token}` },
    body: JSON.stringify({
      org_id: orgId,
      location_id: branch.id,
      full_name: 'Negombo Branch Manager',
      email: employeeEmail,
      password: employeePassword,
      title: 'Branch Manager',
      role: 'manager',
      permissions: { salon_view: true, salon_create: true, salon_move: true, salon_approve: true, salon_allocate: true, customers_view: true, sales_view: true, settings_view: true },
    }),
  });
  const accountResult = await accountResponse.json();
  if (!accountResponse.ok) throw new Error(`Create branch account: ${accountResult.error || accountResponse.statusText}`);
  employeeId = accountResult.user_id;

  const legacyOrg = required(await admin.from('organizations').insert({
    name: `Legacy Employee Setup ${marker}`,
    slug: `legacy-employee-${marker}`,
    owner_id: employeeId,
    email: employeeEmail,
    industry: 'unconfigured',
    business_type: 'unconfigured',
  }).select('id').single(), 'Create legacy extra membership scenario');
  legacyOrgId = legacyOrg.id;
  required(await admin.from('memberships').insert({ org_id: legacyOrgId, user_id: employeeId, role: 'owner', status: 'active' }), 'Create legacy owner membership');
  required(await admin.from('organization_settings').insert({ org_id: legacyOrgId, currency: 'LKR', enabled_modules: [], preferences: { onboarding_completed: false } }), 'Create legacy workspace settings');

  required(await sharedLoginClient.auth.signInWithPassword({ email: ownerEmail, password: ownerPassword }), 'Sign in administrator before branch switch');
  const rejectedAdminPortal = await sharedLoginClient.rpc('validate_employee_login_portal', { p_slug: branch.employee_login_slug });
  if (!rejectedAdminPortal.error?.message.includes('Administrators must use the main login page')) throw new Error('Administrator was not kept on the normal-login rule');

  required(await sharedLoginClient.auth.signInWithPassword({ email: employeeEmail, password: employeePassword }), 'Sign in branch account after administrator session');
  const branchPortal = required(await sharedLoginClient.rpc('validate_employee_login_portal', { p_slug: branch.employee_login_slug }), 'Validate permanent branch login');
  if (branchPortal.location_id !== branch.id || branchPortal.org_id !== orgId) throw new Error('Branch portal resolved the wrong workspace or location');

  const workspaceGate = required(await sharedLoginClient.rpc('get_my_workspace_gate'), 'Resolve assigned branch workspace');
  if (workspaceGate.org_id !== orgId) throw new Error('A legacy extra membership overrode the assigned branch workspace');

  const branchQueries = await Promise.all([
    sharedLoginClient.from('profiles').select('platform_role,must_change_password').eq('id', employeeId).single(),
    sharedLoginClient.from('memberships').select('org_id,role,status,organizations(name,business_type)').eq('user_id', employeeId).eq('org_id', workspaceGate.org_id).single(),
    sharedLoginClient.from('organization_user_access').select('location_id,permissions,salon_locations(id,name,employee_login_slug)').eq('org_id', orgId).eq('user_id', employeeId).single(),
    sharedLoginClient.from('organization_settings').select('preferences').eq('org_id', orgId).single(),
    sharedLoginClient.from('employees').select('id,location_id').eq('org_id', orgId),
    sharedLoginClient.from('salon_appointments').select('id,location_id').eq('org_id', orgId),
    sharedLoginClient.from('salon_services').select('id').eq('org_id', orgId),
    sharedLoginClient.from('salon_locations').select('id').eq('org_id', orgId),
    sharedLoginClient.from('retail_customers').select('id').eq('org_id', orgId),
    sharedLoginClient.from('pos_orders').select('id,location_id').eq('org_id', orgId),
  ]);
  const failedQuery = branchQueries.find((result) => result.error);
  if (failedQuery) throw new Error(`Branch workspace bootstrap: ${failedQuery.error.message}`);
  if (branchQueries[0].data.platform_role !== 'user' || branchQueries[2].data.location_id !== branch.id) throw new Error('Branch account role or location assignment is incorrect');
  if (branchQueries[7].data.some((location) => location.id !== branch.id)) throw new Error('Branch account could see another location');
  required(await sharedLoginClient.from('profiles').update({ must_change_password: false }).eq('id', employeeId), 'Complete first-login password flag');

  required(await sharedLoginClient.auth.signInWithPassword({ email: ownerEmail, password: ownerPassword }), 'Return to administrator login after branch session');
  const ownerProfile = required(await sharedLoginClient.from('profiles').select('platform_role').eq('id', ownerId).single(), 'Reload administrator profile');
  const allBranches = required(await sharedLoginClient.from('salon_locations').select('id').eq('org_id', orgId), 'Load all administrator branches');
  if (ownerProfile.platform_role !== 'super_admin' || allBranches.length < 2) throw new Error('Administrator access was not restored after the branch session');

  console.log(JSON.stringify({
    branchAccountCreatedThroughAdminApi: true,
    permanentBranchLoginWorks: true,
    branchWorkspaceBootstrapWorks: true,
    legacyMembershipDoesNotOverrideBranch: true,
    firstLoginPasswordFlagWorks: true,
    branchIsolationWorks: true,
    administratorLoginWorksAfterBranchSession: true,
  }));
} finally {
  await ownerClient.auth.signOut();
  await sharedLoginClient.auth.signOut();
  if (legacyOrgId) await admin.from('organizations').delete().eq('id', legacyOrgId);
  if (orgId) await admin.from('organizations').delete().eq('id', orgId);
  if (employeeId) await admin.auth.admin.deleteUser(employeeId);
  if (ownerId) await admin.auth.admin.deleteUser(ownerId);
}
