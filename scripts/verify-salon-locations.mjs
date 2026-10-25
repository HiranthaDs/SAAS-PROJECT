import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });
const { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY } = process.env;
if (!SUPABASE_URL || !SUPABASE_PUBLISHABLE_KEY || !SUPABASE_SECRET_KEY) throw new Error('Missing Supabase verification variables');

const admin = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const publicClient = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const marker = crypto.randomUUID().slice(0, 8);
const password = `Salon-${crypto.randomUUID()}!`;
let ownerId = '';
let employeeUserId = '';
let orgId = '';

const required = (result, label) => {
  if (result.error) throw new Error(`${label}: ${result.error.message}`);
  return result.data;
};

try {
  const owner = required(await admin.auth.admin.createUser({ email: `location-owner-${marker}@example.test`, password, email_confirm: true, user_metadata: { full_name: 'Location Owner', company_name: `Location Test ${marker}` } }), 'Create owner').user;
  ownerId = owner.id;
  orgId = required(await admin.from('memberships').select('org_id').eq('user_id', ownerId).single(), 'Load owner workspace').org_id;
  required(await admin.from('profiles').update({ platform_role: 'super_admin' }).eq('id', ownerId), 'Promote isolated owner');
  const organization = required(await admin.from('organizations').update({ name: `Location Test ${marker}`, business_type: 'salon', industry: 'salon' }).eq('id', orgId).select('booking_slug').single(), 'Activate salon');
  required(await admin.from('organization_settings').update({ preferences: { onboarding_completed: true, opening_time: '09:00', closing_time: '19:00', booking_interval: 30 } }).eq('org_id', orgId), 'Configure hours');

  const ownerClient = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  required(await ownerClient.auth.signInWithPassword({ email: owner.email, password }), 'Sign in owner');
  const primary = required(await ownerClient.from('salon_locations').select('*').eq('org_id', orgId).eq('is_primary', true).single(), 'Load primary location');
  const secondary = required(await ownerClient.rpc('create_salon_location', { p_org_id: orgId, p_name: `Negombo ${marker}`, p_code: 'NEG', p_city: 'Negombo', p_address: 'Negombo', p_phone: '', p_is_primary: false }), 'Create second location');

  const employee = required(await admin.auth.admin.createUser({ email: `location-employee-${marker}@example.test`, password, email_confirm: true, user_metadata: { full_name: 'Branch Employee', company_name: 'Employee setup', provisioning_kind: 'employee' } }), 'Create employee').user;
  employeeUserId = employee.id;
  required(await admin.from('organizations').delete().eq('owner_id', employeeUserId), 'Remove automatic employee workspace');
  required(await admin.from('memberships').insert({ org_id: orgId, user_id: employeeUserId, role: 'member', status: 'active' }), 'Assign membership');
  required(await admin.from('organization_user_access').insert({ org_id: orgId, user_id: employeeUserId, location_id: secondary.id, title: 'Stylist', permissions: { salon_view: true }, created_by: ownerId }), 'Assign branch access');
  const secondaryStaff = required(await admin.from('employees').insert({ org_id: orgId, location_id: secondary.id, user_id: employeeUserId, name: 'Branch Employee', email: employee.email, role_title: 'Stylist', department: 'Salon', employment_status: 'active', bookable_for_appointments: true }).select('id').single(), 'Create employee record');
  required(await admin.from('employees').insert({ org_id: orgId, location_id: primary.id, name: 'Main Stylist', role_title: 'Stylist', department: 'Salon', employment_status: 'active', bookable_for_appointments: true }), 'Create primary staff');
  const service = required(await admin.from('salon_services').insert({ org_id: orgId, name: `Location Service ${marker}`, category: 'Hair', duration_minutes: 60, price: 2500 }).select('id').single(), 'Create service');

  const portal = required(await publicClient.rpc('get_employee_login_portal', { p_slug: secondary.employee_login_slug }), 'Open employee portal');
  if (portal.location_id !== secondary.id) throw new Error('Employee portal did not resolve the correct location');
  const employeeClient = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  required(await employeeClient.auth.signInWithPassword({ email: employee.email, password }), 'Sign in employee');
  const validated = required(await employeeClient.rpc('validate_employee_login_portal', { p_slug: secondary.employee_login_slug }), 'Validate employee portal');
  if (!validated.authorized || validated.location_id !== secondary.id) throw new Error('Employee portal authorization is not location-bound');
  const wrongPortal = await employeeClient.rpc('validate_employee_login_portal', { p_slug: primary.employee_login_slug });
  if (!wrongPortal.error?.message.includes('not assigned')) throw new Error('Employee could use another location portal');

  const target = new Date(Date.now() + 4 * 86400000).toISOString().slice(0, 10);
  const startsAt = new Date(`${target}T10:00:00+05:30`).toISOString();
  const endsAt = new Date(`${target}T11:00:00+05:30`).toISOString();
  required(await admin.from('salon_unavailability').insert({ org_id: orgId, location_id: secondary.id, staff_id: secondaryStaff.id, kind: 'time_off', starts_at: startsAt, ends_at: endsAt, reason: 'Branch-specific verification' }), 'Create exact branch off-time');
  const mainAvailability = required(await publicClient.rpc('get_public_salon_availability', { p_slug: organization.booking_slug, p_service_id: service.id, p_from_date: target, p_to_date: target, p_location_id: primary.id }), 'Load main availability');
  const secondaryAvailability = required(await publicClient.rpc('get_public_salon_availability', { p_slug: organization.booking_slug, p_service_id: service.id, p_from_date: target, p_to_date: target, p_location_id: secondary.id }), 'Load secondary availability');
  const mainSlot = mainAvailability.days[0].slots.find((slot) => slot.time === '10:00');
  const secondarySlot = secondaryAvailability.days[0].slots.find((slot) => slot.time === '10:00');
  if (!mainSlot?.available || secondarySlot?.available) throw new Error('Off-time leaked to another branch or failed to block its exact branch');

  const immutable = await admin.from('salon_locations').update({ employee_login_slug: `changed-${marker}` }).eq('id', secondary.id);
  if (!immutable.error?.message.includes('cannot be changed')) throw new Error('Permanent employee link was changeable');
  console.log(JSON.stringify({ locations: true, permanentEmployeeLink: true, employeePortalAccess: true, wrongBranchDenied: true, exactBranchOffTime: true }));
} finally {
  if (orgId) await admin.from('organizations').delete().eq('id', orgId);
  if (employeeUserId) await admin.auth.admin.deleteUser(employeeUserId);
  if (ownerId) await admin.auth.admin.deleteUser(ownerId);
}
