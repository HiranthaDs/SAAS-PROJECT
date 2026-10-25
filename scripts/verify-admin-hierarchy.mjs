import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });
const { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY } = process.env;
if (!SUPABASE_URL || !SUPABASE_PUBLISHABLE_KEY || !SUPABASE_SECRET_KEY) throw new Error('Missing Supabase verification variables');

const authOptions = { auth: { persistSession: false, autoRefreshToken: false } };
const admin = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, authOptions);
const publicClient = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, authOptions);
const marker = crypto.randomUUID().slice(0, 8);
const password = `Hierarchy-${crypto.randomUUID()}!`;
const userIds = [];
const orgIds = [];

const required = (result, label) => {
  if (result.error) throw new Error(`${label}: ${result.error.message}`);
  return result.data;
};

async function createWorkspaceOwner(label) {
  const email = `hierarchy-${label}-${marker}@example.test`;
  const user = required(await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name: `${label} Owner`, company_name: `${label} Workspace ${marker}`, provisioning_kind: 'workspace_owner' },
  }), `Create ${label} owner`).user;
  userIds.push(user.id);
  const membership = required(await admin.from('memberships').select('org_id').eq('user_id', user.id).single(), `Load ${label} workspace`);
  orgIds.push(membership.org_id);
  return { user, orgId: membership.org_id };
}

try {
  const first = await createWorkspaceOwner('First');
  const second = await createWorkspaceOwner('Second');
  const firstProfile = required(await admin.from('profiles').select('platform_role').eq('id', first.user.id).single(), 'Read first owner role');
  if (firstProfile.platform_role !== 'super_admin') throw new Error('First account creator was not promoted to workspace super administrator');

  const organization = required(await admin.from('organizations').update({
    business_type: 'salon',
    industry: 'salon',
    name: `Hierarchy Salon ${marker}`,
  }).eq('id', first.orgId).select('booking_slug').single(), 'Activate first salon');
  required(await admin.from('organizations').update({ business_type: 'salon', industry: 'salon' }).eq('id', second.orgId), 'Activate second salon');

  const firstClient = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, authOptions);
  required(await firstClient.auth.signInWithPassword({ email: first.user.email, password }), 'Sign in first owner');
  const branch = required(await firstClient.rpc('create_salon_location', {
    p_org_id: first.orgId,
    p_name: `Colombo Branch ${marker}`,
    p_code: 'COL',
    p_city: 'Colombo',
    p_address: 'Colombo',
    p_phone: '',
    p_is_primary: false,
  }), 'Workspace owner creates own location');
  const crossTenant = await firstClient.rpc('create_salon_location', {
    p_org_id: second.orgId,
    p_name: 'Unauthorized Branch',
    p_code: 'NO',
    p_city: '',
    p_address: '',
    p_phone: '',
    p_is_primary: false,
  });
  if (!crossTenant.error?.message.includes('workspace super administrator')) throw new Error('Workspace owner could create a location in another workspace');

  const escalation = await firstClient.from('profiles').update({ platform_role: 'system_admin' }).eq('id', first.user.id);
  if (!escalation.error) throw new Error('Workspace owner could promote their own platform role');

  const employee = required(await admin.auth.admin.createUser({
    email: `hierarchy-employee-${marker}@example.test`,
    password,
    email_confirm: true,
    user_metadata: { full_name: 'Branch Manager', company_name: 'Employee setup', provisioning_kind: 'employee' },
  }), 'Create branch account').user;
  userIds.push(employee.id);
  required(await admin.from('organizations').delete().eq('owner_id', employee.id), 'Remove temporary employee workspace');
  required(await admin.from('memberships').insert({ org_id: first.orgId, user_id: employee.id, role: 'manager', status: 'active' }), 'Assign branch membership');
  required(await admin.from('organization_user_access').insert({
    org_id: first.orgId,
    user_id: employee.id,
    location_id: branch.id,
    title: 'Branch Manager',
    permissions: { salon_view: true, salon_create: true, salon_move: true, salon_approve: true, salon_allocate: true, customers_view: true, sales_view: true, settings_view: false },
    created_by: first.user.id,
  }), 'Assign branch permissions');

  const employeeClient = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, authOptions);
  required(await employeeClient.auth.signInWithPassword({ email: employee.email, password }), 'Sign in branch manager');
  const employeePortal = required(await employeeClient.rpc('validate_employee_login_portal', { p_slug: branch.employee_login_slug }), 'Validate assigned branch portal');
  if (employeePortal.location_id !== branch.id) throw new Error('Branch account was not restricted to its assigned location');

  const system = await createWorkspaceOwner('System');
  required(await admin.from('profiles').update({ platform_role: 'system_admin' }).eq('id', system.user.id), 'Promote temporary system administrator');
  const systemClient = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, authOptions);
  required(await systemClient.auth.signInWithPassword({ email: system.user.email, password }), 'Sign in system administrator');
  const consoleData = required(await systemClient.rpc('get_system_admin_console'), 'Load system administration console');
  if (!consoleData.organizations.some((item) => item.id === first.orgId) || !consoleData.organizations.some((item) => item.id === second.orgId)) {
    throw new Error('System administrator could not see all workspaces');
  }

  required(await systemClient.rpc('set_organization_access_state', {
    p_org_id: first.orgId,
    p_account_status: 'suspended',
    p_billing_status: 'suspended',
    p_reason: 'Automated nonpayment test',
  }), 'Suspend customer workspace');

  const gate = required(await firstClient.rpc('get_my_workspace_gate'), 'Read suspended workspace gate');
  if (gate.account_status !== 'suspended' || gate.billing_status !== 'suspended') throw new Error('Suspension was not visible to the workspace owner');
  const hiddenLocations = required(await firstClient.from('salon_locations').select('id').eq('org_id', first.orgId), 'Check suspended data access');
  if (hiddenLocations.length !== 0) throw new Error('Suspended workspace could still read protected data');
  const publicBooking = await publicClient.rpc('get_public_salon_booking', { p_slug: organization.booking_slug });
  if (!publicBooking.error?.message.includes('unavailable')) throw new Error('Suspended public booking link remained available');
  const suspendedPortal = await publicClient.rpc('get_employee_login_portal', { p_slug: branch.employee_login_slug });
  if (!suspendedPortal.error?.message.includes('unavailable')) throw new Error('Suspended employee login portal remained available');

  required(await systemClient.rpc('set_organization_access_state', {
    p_org_id: first.orgId,
    p_account_status: 'active',
    p_billing_status: 'paid',
    p_reason: '',
  }), 'Reactivate customer workspace');
  required(await publicClient.rpc('get_public_salon_booking', { p_slug: organization.booking_slug }), 'Restore public booking link');

  console.log(JSON.stringify({
    firstCreatorIsWorkspaceSuperAdmin: true,
    crossWorkspaceIsolation: true,
    selfRoleEscalationBlocked: true,
    branchPortalRestricted: true,
    systemAdminSeesAllWorkspaces: true,
    suspensionBlocksWorkspaceAndPublicLinks: true,
    reactivationRestoresAccess: true,
  }));
} finally {
  for (const orgId of [...new Set(orgIds)].reverse()) await admin.from('organizations').delete().eq('id', orgId);
  for (const userId of [...new Set(userIds)].reverse()) await admin.auth.admin.deleteUser(userId);
}
