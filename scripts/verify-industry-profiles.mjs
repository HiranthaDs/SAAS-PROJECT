import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });
const client = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const login = await client.auth.signInWithPassword({ email: process.env.SUPER_ADMIN_EMAIL, password: process.env.SUPER_ADMIN_PASSWORD });
if (login.error) throw login.error;
const membership = await client.from('memberships').select('org_id').eq('user_id', login.data.user.id).limit(1).single();
if (membership.error) throw membership.error;
const orgId = membership.data.org_id;
const marker = crypto.randomUUID().slice(0, 8);
let productId;
let prescriptionId;
let appointmentId;
let vehicleId;
let jobId;

try {
  const profiles = {};
  for (const type of ['retail_grocery', 'pharmacy', 'salon', 'automotive', 'general_erp']) {
    const result = await client.rpc('modules_for_business_type', { target_type: type });
    if (result.error) throw result.error;
    profiles[type] = result.data;
  }
  if (!profiles.pharmacy.includes('pharmacy') || !profiles.salon.includes('salon') || !profiles.automotive.includes('automotive') || profiles.retail_grocery.includes('salon')) {
    throw new Error('Industry module isolation failed');
  }

  const product = await client.from('products').insert({ org_id: orgId, sku: `MED-${marker}`, name: `Test Medicine ${marker}`, category: 'Medicine', stock: 20, forecast: 20, cost: 10, price: 15 }).select().single();
  if (product.error) throw product.error;
  productId = product.data.id;
  const prescription = await client.from('pharmacy_prescriptions').insert({ org_id: orgId, number: `RX-${marker}`, patient_name: 'Verification Patient', prescriber: 'Dr Test', items: [{ product_id: productId, name: product.data.name, quantity: 3, dosage: 'Test dosage' }], created_by: login.data.user.id }).select().single();
  if (prescription.error) throw prescription.error;
  prescriptionId = prescription.data.id;
  const verified = await client.rpc('advance_prescription', { p_prescription_id: prescriptionId });
  if (verified.error || verified.data !== 'verified') throw verified.error || new Error('Prescription verification failed');
  const dispensed = await client.rpc('advance_prescription', { p_prescription_id: prescriptionId });
  if (dispensed.error || dispensed.data !== 'dispensed') throw dispensed.error || new Error('Prescription dispensing failed');
  const stock = await client.from('products').select('stock').eq('id', productId).single();
  if (stock.error || Number(stock.data.stock) !== 17) throw stock.error || new Error('Prescription stock control failed');

  const appointment = await client.from('salon_appointments').insert({ org_id: orgId, customer_name: 'Verification Client', customer_phone: '0770000000', service_name: 'Verification Service', starts_at: '2099-01-01T09:00:00Z', ends_at: '2099-01-01T10:00:00Z', price: 2500, created_by: login.data.user.id }).select().single();
  if (appointment.error) throw appointment.error;
  appointmentId = appointment.data.id;
  const appointmentUpdated = await client.from('salon_appointments').update({ status: 'confirmed' }).eq('id', appointmentId).select('status').single();
  if (appointmentUpdated.error || appointmentUpdated.data.status !== 'confirmed') throw appointmentUpdated.error || new Error('Salon appointment workflow failed');

  const vehicle = await client.from('vehicles').insert({ org_id: orgId, registration_number: `TEST-${marker}`, make: 'Test', model: 'Vehicle', current_mileage: 10000 }).select().single();
  if (vehicle.error) throw vehicle.error;
  vehicleId = vehicle.data.id;
  const job = await client.from('workshop_job_cards').insert({ org_id: orgId, number: `JOB-${marker}`, vehicle_id: vehicleId, customer_name: 'Verification Driver', complaint: 'Verification service', odometer_in: 10000, estimate_amount: 12000, created_by: login.data.user.id }).select().single();
  if (job.error) throw job.error;
  jobId = job.data.id;
  const inspected = await client.rpc('advance_job_card', { p_job_id: jobId });
  const approval = await client.rpc('advance_job_card', { p_job_id: jobId });
  if (inspected.error || approval.error || inspected.data !== 'inspection' || approval.data !== 'approval') throw inspected.error || approval.error || new Error('Workshop workflow failed');

  console.log(JSON.stringify({
    moduleIsolation: true,
    pharmacy: { verified: true, dispensed: true, stockReduced: true },
    salon: { appointmentBooked: true, confirmed: true },
    automotive: { vehicleRegistered: true, jobCardCreated: true, advancedToApproval: true },
  }));
} finally {
  if (prescriptionId) await admin.from('pharmacy_prescriptions').delete().eq('id', prescriptionId);
  if (productId) {
    await admin.from('stock_movements').delete().eq('product_id', productId);
    await admin.from('products').delete().eq('id', productId);
  }
  if (appointmentId) await admin.from('salon_appointments').delete().eq('id', appointmentId);
  if (jobId) await admin.from('workshop_job_cards').delete().eq('id', jobId);
  if (vehicleId) await admin.from('vehicles').delete().eq('id', vehicleId);
  await client.auth.signOut();
}
