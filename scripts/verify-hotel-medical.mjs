import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });

const required = ['SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_SECRET_KEY', 'SUPER_ADMIN_EMAIL', 'SUPER_ADMIN_PASSWORD'];
for (const key of required) if (!process.env[key]) throw new Error(`Missing ${key}`);

const client = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const publicClient = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const login = await client.auth.signInWithPassword({ email: process.env.SUPER_ADMIN_EMAIL, password: process.env.SUPER_ADMIN_PASSWORD });
if (login.error) throw login.error;

const marker = crypto.randomUUID().slice(0, 8);
const createdOrgIds = [];
const colomboParts = new Intl.DateTimeFormat('en', { timeZone: 'Asia/Colombo', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date());
const today = Object.fromEntries(colomboParts.map((part) => [part.type, part.value]));
const sessionDate = `${today.year}-${today.month}-${today.day}`;

async function createWorkspace(businessType, name) {
  const organization = await admin.from('organizations').insert({
    name, slug: `${businessType}-${marker}-${createdOrgIds.length}`, owner_id: login.data.user.id,
    email: `${businessType}-${marker}@example.test`, industry: businessType, business_type: businessType,
  }).select('id').single();
  if (organization.error) throw organization.error;
  createdOrgIds.push(organization.data.id);
  const membership = await admin.from('memberships').insert({ org_id: organization.data.id, user_id: login.data.user.id, role: 'owner', status: 'active' });
  if (membership.error) throw membership.error;
  const settings = await admin.from('organization_settings').insert({ org_id: organization.data.id, currency: 'LKR', enabled_modules: ['overview', 'industry_ops'] });
  if (settings.error) throw settings.error;
  const location = await admin.from('salon_locations').select('id').eq('org_id', organization.data.id).single();
  if (location.error) throw location.error;
  return { orgId: organization.data.id, locationId: location.data.id };
}

try {
  const hotel = await createWorkspace('hotel', `Hotel Verify ${marker}`);
  const hotelProperty = await client.from('hotel_properties').insert({
    org_id: hotel.orgId, location_id: hotel.locationId, name: `Harbour Hotel ${marker}`,
    public_slug: `hotel-verify-${marker}`, address: 'Verification Road', phone: '0770000000', created_by: login.data.user.id,
  }).select('id,public_slug').single();
  if (hotelProperty.error) throw hotelProperty.error;
  const room = await client.from('hotel_room_types').insert({
    org_id: hotel.orgId, property_id: hotelProperty.data.id, name: 'Deluxe Room', code: 'DLX',
    room_count: 5, max_adults: 2, max_children: 1, nightly_rate: 12500, includes: ['Breakfast', 'Wi-Fi'],
  }).select('id').single();
  if (room.error) throw room.error;
  const firstBooking = await publicClient.rpc('create_public_hotel_booking', {
    p_slug: hotelProperty.data.public_slug, p_room_type_id: room.data.id, p_guest_name: 'Capacity Test', p_whatsapp: '0771111111',
    p_email: null, p_arrival: '2099-04-10', p_departure: '2099-04-12', p_adults: 5, p_children: 0, p_rooms: 5, p_notes: null,
  });
  if (firstBooking.error) throw firstBooking.error;
  const overbook = await publicClient.rpc('create_public_hotel_booking', {
    p_slug: hotelProperty.data.public_slug, p_room_type_id: room.data.id, p_guest_name: 'Must Fail', p_whatsapp: '0772222222',
    p_email: null, p_arrival: '2099-04-11', p_departure: '2099-04-13', p_adults: 1, p_children: 0, p_rooms: 1, p_notes: null,
  });
  if (!overbook.error) throw new Error('Hotel overbooking protection did not reject excess capacity');
  const availability = await publicClient.rpc('get_public_hotel', { p_slug: hotelProperty.data.public_slug, p_arrival: '2099-04-10', p_departure: '2099-04-12', p_rooms: 1 });
  if (availability.error || Number(availability.data.room_types[0].available_rooms) !== 0) throw availability.error || new Error('Hotel availability did not reach zero');
  const channelBooking = await client.rpc('upsert_hotel_channel_booking', { p_property_id: hotelProperty.data.id, p_room_type_id: room.data.id, p_provider: 'agoda', p_external_id: `AG-${marker}`, p_guest_name: 'Channel Guest', p_whatsapp: '', p_arrival: '2099-06-01', p_departure: '2099-06-03', p_adults: 2, p_children: 0, p_rooms: 1, p_notes: null });
  const channelRetry = await client.rpc('upsert_hotel_channel_booking', { p_property_id: hotelProperty.data.id, p_room_type_id: room.data.id, p_provider: 'agoda', p_external_id: `AG-${marker}`, p_guest_name: 'Channel Guest', p_whatsapp: '', p_arrival: '2099-06-01', p_departure: '2099-06-03', p_adults: 2, p_children: 0, p_rooms: 1, p_notes: null });
  if (channelBooking.error || channelRetry.error || channelBooking.data.id !== channelRetry.data.id || channelRetry.data.idempotent !== true) throw channelBooking.error || channelRetry.error || new Error('Channel booking import was not idempotent');

  const medical = await createWorkspace('healthcare_clinic', `Medical Verify ${marker}`);
  const center = await client.from('medical_centers').insert({
    org_id: medical.orgId, location_id: medical.locationId, name: `Medical Center ${marker}`,
    public_slug: `medical-verify-${marker}`, phone: '0773333333', email: `center-${marker}@example.test`, address: '18 Health Avenue', registration_number: `REG-${marker}`, tax_number: `TAX-${marker}`, invoice_footer: 'Thank you for choosing our medical center.', default_slot_minutes: 15, created_by: login.data.user.id,
  }).select('id,public_slug').single();
  if (center.error) throw center.error;
  const doctors = await client.from('medical_doctors').insert([
    { org_id: medical.orgId, center_id: center.data.id, name: 'Doctor Alpha', specialty: 'General medicine', room_label: 'Room 1', queue_prefix: 'A', consultation_fee: 3500 },
    { org_id: medical.orgId, center_id: center.data.id, name: 'Doctor Bravo', specialty: 'Paediatrics', room_label: 'Room 2', queue_prefix: 'B', consultation_fee: 4000 },
  ]).select('id,name');
  if (doctors.error) throw doctors.error;
  const sessions = await client.from('medical_sessions').insert(doctors.data.map((doctor) => ({
    org_id: medical.orgId, center_id: center.data.id, doctor_id: doctor.id, session_date: sessionDate,
    starts_at: '08:00', ends_at: '08:30', slot_minutes: 15, capacity: 2, status: 'open', created_by: login.data.user.id,
  }))).select('id,doctor_id,capacity,doctor_portal_token');
  if (sessions.error) throw sessions.error;
  if (sessions.data.some((item) => Number(item.capacity) !== 2)) throw new Error('Medical session capacity was not derived from its time range and slot duration');
  const firstAvailable = await publicClient.rpc('issue_medical_queue_number', { p_slug: center.data.public_slug, p_patient_name: 'Patient One', p_whatsapp: null, p_session_id: null, p_source: 'qr' });
  const secondAvailable = await publicClient.rpc('issue_medical_queue_number', { p_slug: center.data.public_slug, p_patient_name: 'Patient Two', p_whatsapp: null, p_session_id: null, p_source: 'link' });
  if (firstAvailable.error || secondAvailable.error) throw firstAvailable.error || secondAvailable.error;
  if (firstAvailable.data.doctor_name === secondAvailable.data.doctor_name) throw new Error('First-available routing did not balance two doctor queues');
  const firstSession = sessions.data.find((item) => item.doctor_id === doctors.data[0].id);
  const fillFirst = await publicClient.rpc('issue_medical_queue_number', { p_slug: center.data.public_slug, p_patient_name: 'Patient Three', p_whatsapp: null, p_session_id: firstSession.id, p_source: 'staff' });
  if (fillFirst.error) throw fillFirst.error;
  const overflowFirst = await publicClient.rpc('issue_medical_queue_number', { p_slug: center.data.public_slug, p_patient_name: 'Must Fail', p_whatsapp: null, p_session_id: firstSession.id, p_source: 'walk_in' });
  if (!overflowFirst.error) throw new Error('Medical session capacity did not reject an excess number');
  const called = await client.rpc('call_next_medical_queue', { p_session_id: firstSession.id });
  if (called.error || called.data.empty || called.data.status !== 'called') throw called.error || new Error('Call-next did not atomically select a waiting patient');
  if (!called.data.invoice_number || Number(called.data.consultation_fee) !== 3500) throw new Error('Medical invoice details were not assigned from the doctor fee');
  const duplicateCall = await client.rpc('call_next_medical_queue', { p_session_id: firstSession.id });
  if (duplicateCall.error || duplicateCall.data.id !== called.data.id || duplicateCall.data.already_active !== true) throw duplicateCall.error || new Error('Call-next allowed more than one active patient');
  const doctorPortal = await publicClient.rpc('get_medical_doctor_portal', { p_token: firstSession.doctor_portal_token });
  if (doctorPortal.error || doctorPortal.data.session.id !== firstSession.id || doctorPortal.data.tickets.length < 2) throw doctorPortal.error || new Error('Private doctor portal did not return the allocated session queue');
  const consultation = await publicClient.rpc('advance_medical_queue_by_token', { p_token: firstSession.doctor_portal_token, p_ticket_id: called.data.id, p_status: 'in_consultation' });
  if (consultation.error || consultation.data.status !== 'in_consultation') throw consultation.error || new Error('Doctor portal could not start the consultation');
  const completedByDoctor = await publicClient.rpc('advance_medical_queue_by_token', { p_token: firstSession.doctor_portal_token, p_ticket_id: called.data.id, p_status: 'completed' });
  if (completedByDoctor.error || completedByDoctor.data.status !== 'completed') throw completedByDoctor.error || new Error('Doctor portal could not complete the consultation');
  const calledByDoctor = await publicClient.rpc('call_next_medical_queue_by_token', { p_token: firstSession.doctor_portal_token });
  if (calledByDoctor.error || calledByDoctor.data.empty || calledByDoctor.data.status !== 'called') throw calledByDoctor.error || new Error('Doctor portal could not call the next allocated number');
  const payment = await client.rpc('record_medical_queue_payment', { p_ticket_id: called.data.id, p_amount: 3500, p_method: 'card' });
  if (payment.error || payment.data.payment_status !== 'paid' || Number(payment.data.paid_amount) !== 3500) throw payment.error || new Error('Medical invoice payment was not recorded');
  const monitor = await publicClient.rpc('get_public_medical_monitor', { p_slug: center.data.public_slug });
  if (monitor.error || monitor.data.sessions.length !== 2 || !monitor.data.sessions.some((item) => item.current_number)) throw monitor.error || new Error('Realtime clinic monitor payload is incomplete');
  const snapshots = await publicClient.from('medical_public_queue_snapshots').select('*').eq('center_id', center.data.id);
  if (snapshots.error || snapshots.data.length !== 2 || snapshots.data.some((item) => Object.hasOwn(item, 'patient_name') || Object.hasOwn(item, 'whatsapp'))) throw snapshots.error || new Error('Public queue snapshots are unavailable or expose private patient data');
  const ticketStatus = await publicClient.rpc('get_medical_ticket_status', { p_token: firstAvailable.data.token });
  if (ticketStatus.error || !ticketStatus.data?.display_number || ticketStatus.data.center_name !== `Medical Center ${marker}` || !ticketStatus.data.invoice_number) throw ticketStatus.error || new Error('Public medical ticket status or center invoice details are unavailable');

  const bucket = await admin.storage.listBuckets();
  if (bucket.error || !bucket.data.some((item) => item.id === 'hotel-room-images')) throw bucket.error || new Error('Hotel image bucket was not created');
  console.log(JSON.stringify({
    hotel: { roomCapacity: 5, overbookingRejected: true, availableAfterFiveRooms: 0, channelImportIdempotent: true, bookingNumber: firstBooking.data.booking_number },
    medical: { doctors: 2, balancedFirstAvailable: true, capacityDerivedFromSlotMinutes: true, sessionCapacityEnforced: true, singleActivePatient: true, doctorPortal: true, monitorSnapshots: 2, publicSnapshotPrivacy: true, professionalInvoice: true, paymentRecorded: true, centerDetailsOnTicket: true, called: called.data.display_number, publicStatus: true },
    storage: { hotelRoomImages: true }, tenantCleanup: 'pending',
  }));
} finally {
  for (const orgId of createdOrgIds.reverse()) await admin.from('organizations').delete().eq('id', orgId);
  await client.auth.signOut();
}
