import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });

const { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY } = process.env;
if (!SUPABASE_URL || !SUPABASE_PUBLISHABLE_KEY || !SUPABASE_SECRET_KEY) {
  throw new Error('Missing Supabase verification environment variables');
}

const admin = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const publicClient = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const marker = crypto.randomUUID().slice(0, 8);
const email = `salon-flow-${marker}@example.test`;
const password = `Salon-${crypto.randomUUID()}!`;
let userId;
let orgId;

function requireResult(result, label) {
  if (result.error) throw new Error(`${label}: ${result.error.message}`);
  return result.data;
}

try {
  const created = requireResult(await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name: 'Salon Flow Test', company_name: `Salon Flow ${marker}` },
  }), 'Create test owner');
  userId = created.user.id;

  const membership = requireResult(
    await admin.from('memberships').select('org_id').eq('user_id', userId).single(),
    'Load provisioned workspace',
  );
  orgId = membership.org_id;

  const organization = requireResult(
    await admin.from('organizations').update({
      name: `Salon Flow ${marker}`,
      business_type: 'salon',
      industry: 'salon',
      phone: '0771234567',
      address: 'Colombo',
    }).eq('id', orgId).select('booking_slug').single(),
    'Activate salon workspace',
  );
  if (!organization.booking_slug) throw new Error('Salon booking slug was not generated');

  requireResult(await admin.from('organization_settings').update({
    enabled_modules: ['overview', 'salon', 'service_catalog', 'reminders', 'pos', 'sales_history', 'customers', 'inventory', 'finance', 'people'],
    preferences: { onboarding_completed: true, opening_time: '09:00', closing_time: '19:00', booking_interval: 30 },
  }).eq('org_id', orgId), 'Configure salon workspace');

  requireResult(await admin.from('employees').insert([{
    org_id: orgId,
    name: 'Test Stylist',
    role_title: 'Stylist',
    department: 'Salon',
    bookable_for_appointments: true,
  }, {
    org_id: orgId,
    name: 'Second Stylist',
    role_title: 'Colourist',
    department: 'Salon',
    bookable_for_appointments: true,
  }]), 'Create bookable salon staff');

  const service = requireResult(await admin.from('salon_services').insert({
    org_id: orgId,
    name: `Cut & Finish ${marker}`,
    category: 'Hair',
    description: 'Consultation, treatment, and finish',
    duration_minutes: 60,
    price: 2500,
  }).select('id,name,price').single(), 'Create bookable service');

  const bookingPage = requireResult(
    await publicClient.rpc('get_public_salon_booking', { p_slug: organization.booking_slug }),
    'Load public booking page',
  );
  if (bookingPage.services?.[0]?.id !== service.id || bookingPage.services[0].description !== 'Consultation, treatment, and finish') {
    throw new Error('Public service catalogue is not connected');
  }
  if (bookingPage.capacity !== 2) throw new Error('Public booking capacity does not match bookable staff');

  const start = new Date(Date.now() + 48 * 60 * 60 * 1000);
  start.setUTCHours(4, 30, 0, 0);
  const booking = requireResult(await publicClient.rpc('book_public_salon_appointment', {
    p_slug: organization.booking_slug,
    p_service_id: service.id,
    p_customer_name: 'Public Booking Client',
    p_customer_phone: '077 555 0199',
    p_customer_email: '',
    p_starts_at: start.toISOString(),
    p_notes: 'Automated booking verification',
  }), 'Create public appointment');

  const simultaneousBooking = requireResult(await publicClient.rpc('book_public_salon_appointment', {
    p_slug: organization.booking_slug,
    p_service_id: service.id,
    p_customer_name: 'Second Public Client',
    p_customer_phone: '077 555 0200',
    p_customer_email: '',
    p_starts_at: start.toISOString(),
    p_notes: 'Capacity verification',
  }), 'Create second simultaneous appointment');
  if (!simultaneousBooking.staff || simultaneousBooking.staff === booking.staff) {
    throw new Error('Simultaneous bookings were not assigned to separate staff');
  }
  const overCapacity = await publicClient.rpc('book_public_salon_appointment', {
    p_slug: organization.booking_slug,
    p_service_id: service.id,
    p_customer_name: 'Over Capacity Client',
    p_customer_phone: '077 555 0201',
    p_customer_email: '',
    p_starts_at: start.toISOString(),
    p_notes: '',
  });
  if (!overCapacity.error?.message.includes('fully booked')) throw new Error('Staff capacity limit was not enforced');

  const bookingDate = new Date(start.getTime() + 330 * 60 * 1000).toISOString().slice(0, 10);
  const fullSlotAvailability = requireResult(await publicClient.rpc('get_public_salon_availability', {
    p_slug: organization.booking_slug,
    p_service_id: service.id,
    p_from_date: bookingDate,
    p_to_date: bookingDate,
  }), 'Load slot availability');
  const bookedSlot = fullSlotAvailability.days?.[0]?.slots?.find((slot) => slot.time === '10:00');
  if (!bookedSlot || bookedSlot.available || bookedSlot.remaining !== 0) {
    throw new Error('Fully booked time slot was not marked unavailable');
  }

  const blockedStart = new Date(start.getTime() + 24 * 60 * 60 * 1000);
  const blockedDate = new Date(blockedStart.getTime() + 330 * 60 * 1000).toISOString().slice(0, 10);
  requireResult(await admin.from('salon_unavailability').insert({
    org_id: orgId,
    staff_id: null,
    kind: 'salon_closed',
    starts_at: new Date(`${blockedDate}T00:00:00+05:30`).toISOString(),
    ends_at: new Date(`${blockedDate}T23:59:59+05:30`).toISOString(),
    reason: 'Verification closure',
  }), 'Create salon closure');
  const blockedBooking = await publicClient.rpc('book_public_salon_appointment', {
    p_slug: organization.booking_slug,
    p_service_id: service.id,
    p_customer_name: 'Closed Time Client',
    p_customer_phone: '077 555 0202',
    p_customer_email: '',
    p_starts_at: blockedStart.toISOString(),
    p_notes: '',
  });
  if (!blockedBooking.error?.message.includes('unavailable')) throw new Error('Salon closure was not enforced');
  const closedDayAvailability = requireResult(await publicClient.rpc('get_public_salon_availability', {
    p_slug: organization.booking_slug,
    p_service_id: service.id,
    p_from_date: blockedDate,
    p_to_date: blockedDate,
  }), 'Load closed day availability');
  if (closedDayAvailability.days?.[0]?.available !== false || closedDayAvailability.days[0].slots.some((slot) => slot.available)) {
    throw new Error('Closed date was not marked unavailable');
  }

  const signedInClient = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  requireResult(await signedInClient.auth.signInWithPassword({ email, password }), 'Sign in salon owner');

  const appointment = requireResult(await signedInClient.from('salon_appointments')
    .select('id,customer_id,service_id,source,reminder_status')
    .eq('id', booking.appointment_id)
    .single(), 'Read appointment in admin portal');
  if (appointment.source !== 'public_booking' || !appointment.customer_id) {
    throw new Error('Public booking did not create the connected appointment and customer');
  }

  requireResult(await signedInClient.rpc('mark_whatsapp_reminder_sent', {
    p_appointment_id: appointment.id,
  }), 'Log WhatsApp reminder');

  const receipt = requireResult(await signedInClient.rpc('checkout_pos', {
    p_org_id: orgId,
    p_items: [{ service_id: service.id, appointment_id: appointment.id, quantity: 1 }],
    p_customer_id: appointment.customer_id,
    p_payment_method: 'cash',
    p_amount_tendered: 3000,
    p_loyalty_redeemed: 0,
    p_store_change_as_loyalty: false,
  }), 'Checkout booked service');

  const checkedOut = requireResult(await signedInClient.from('salon_appointments')
    .select('status,reminder_status,pos_order_id')
    .eq('id', appointment.id)
    .single(), 'Verify appointment checkout');
  if (checkedOut.status !== 'completed' || checkedOut.reminder_status !== 'sent' || checkedOut.pos_order_id !== receipt.order_id) {
    throw new Error('Appointment, reminder, and POS receipt were not linked');
  }

  const orderItem = requireResult(await signedInClient.from('pos_order_items')
    .select('item_type,service_id')
    .eq('pos_order_id', receipt.order_id)
    .single(), 'Verify service receipt line');
  if (orderItem.item_type !== 'service' || orderItem.service_id !== service.id) {
    throw new Error('POS did not bill from the salon service catalogue');
  }

  await signedInClient.auth.signOut();
  console.log(JSON.stringify({
    publicBooking: true,
    simultaneousCapacity: true,
    unavailability: true,
    publicAvailabilityColours: true,
    serviceCatalogue: true,
    customerProfile: true,
    calendarAppointment: true,
    whatsappReminder: true,
    serviceCheckout: true,
    receiptLinked: true,
  }));
} finally {
  if (orgId) await admin.from('organizations').delete().eq('id', orgId);
  if (userId) await admin.auth.admin.deleteUser(userId);
}
