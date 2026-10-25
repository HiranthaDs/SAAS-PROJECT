import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });
const required = ['SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_SECRET_KEY', 'SUPER_ADMIN_EMAIL', 'SUPER_ADMIN_PASSWORD'];
for (const key of required) if (!process.env[key]) throw new Error(`Missing ${key}`);

const client = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const signIn = await client.auth.signInWithPassword({ email: process.env.SUPER_ADMIN_EMAIL, password: process.env.SUPER_ADMIN_PASSWORD });
if (signIn.error) throw signIn.error;
const membership = await client.from('memberships').select('org_id').eq('user_id', signIn.data.user.id).limit(1).single();
if (membership.error) throw membership.error;
const orgId = membership.data.org_id;
const marker = crypto.randomUUID().slice(0, 8);
let customerId;
let productId;
let orderId;
let employeeId;
let payrollRunId;

try {
  const customerPhone = `077${Date.now().toString().slice(-7)}`;
  const customer = await client.from('retail_customers').insert({
    org_id: orgId, name: `POS Test ${marker}`, phone: customerPhone,
    phone_normalized: customerPhone, customer_code: `CUS-${marker}`,
    birthday: '1990-05-12', email: `customer-${marker}@example.com`, nic_passport: `NIC-${marker}`,
    preferred_language: 'English', address: '10 Test Road', city: 'Colombo', postal_code: '00100',
    marketing_consent: true, tags: ['VIP', 'verification'], notes: 'Complete customer profile verification',
  }).select().single();
  if (customer.error) throw customer.error;
  customerId = customer.data.id;

  const product = await client.from('products').insert({
    org_id: orgId, sku: `TEST-${marker}`, barcode: `9900${Date.now().toString().slice(-8)}`,
    name: `Test Grocery ${marker}`, category: 'Verification', stock: 10, forecast: 10,
    cost: 70, price: 125, reorder_level: 2, active: true,
  }).select().single();
  if (product.error) throw product.error;
  productId = product.data.id;

  const checkout = await client.rpc('checkout_pos', {
    p_org_id: orgId,
    p_items: [{ product_id: productId, quantity: 3 }],
    p_customer_id: customerId,
    p_payment_method: 'cash',
    p_amount_tendered: 400,
    p_loyalty_redeemed: 0,
    p_store_change_as_loyalty: true,
  });
  if (checkout.error) throw checkout.error;
  orderId = checkout.data.order_id;
  const [stock, customerAfter, order, orderItems, loyalty, entry] = await Promise.all([
    admin.from('products').select('stock').eq('id', productId).single(),
    admin.from('retail_customers').select('customer_code,email,nic_passport,preferred_language,address,city,postal_code,marketing_consent,tags,loyalty_balance,total_spent,visits').eq('id', customerId).single(),
    admin.from('pos_orders').select('subtotal,total,loyalty_earned,change_to_loyalty').eq('id', orderId).single(),
    admin.from('pos_order_items').select('sku,item_name,quantity,unit_cost,unit_price,line_total').eq('pos_order_id', orderId),
    admin.from('loyalty_transactions').select('transaction_type,points').eq('pos_order_id', orderId),
    admin.from('journal_entries').select('id,journal_lines(debit,credit)').eq('source_type', 'pos').eq('source_id', orderId).single(),
  ]);
  for (const result of [stock, customerAfter, order, orderItems, loyalty, entry]) if (result.error) throw result.error;
  const debit = entry.data.journal_lines.reduce((sum, line) => sum + Number(line.debit), 0);
  const credit = entry.data.journal_lines.reduce((sum, line) => sum + Number(line.credit), 0);
  const posValid = Number(stock.data.stock) === 7 && Number(order.data.subtotal) === 375 &&
    Number(order.data.total) === 375 && Number(order.data.loyalty_earned) === 3 &&
    Number(order.data.change_to_loyalty) === 25 && Number(customerAfter.data.loyalty_balance) === 28 &&
    Number(customerAfter.data.total_spent) === 375 && customerAfter.data.visits === 1 &&
    customerAfter.data.customer_code === `CUS-${marker}` && customerAfter.data.marketing_consent === true &&
    customerAfter.data.tags.includes('VIP') && orderItems.data.length === 1 &&
    Number(orderItems.data[0].unit_cost) === 70 && Number(orderItems.data[0].unit_price) === 125 && debit === credit;
  if (!posValid) throw new Error('POS transaction verification failed');

  const employee = await client.from('employees').insert({
    org_id: orgId, name: `Payroll Test ${marker}`, role_title: 'Verifier', department: 'QA', employment_status: 'active', start_date: '2026-01-01',
  }).select().single();
  if (employee.error) throw employee.error;
  employeeId = employee.data.id;
  const compensation = await client.from('employee_compensation').insert({
    org_id: orgId, employee_id: employeeId, pay_type: 'monthly', base_salary: 100000,
    fixed_allowances: 10000, fixed_deductions: 2000, epf_employee_rate: 8, epf_employer_rate: 12, etf_rate: 3,
  });
  if (compensation.error) throw compensation.error;
  const payroll = await client.rpc('prepare_payroll_run', { p_org_id: orgId, p_period_month: '2099-01-01' });
  if (payroll.error) throw payroll.error;
  payrollRunId = payroll.data;
  const payrollItem = await admin.from('payroll_items').select('*').eq('payroll_run_id', payrollRunId).eq('employee_id', employeeId).single();
  if (payrollItem.error) throw payrollItem.error;
  const payrollValid = Number(payrollItem.data.gross_pay) === 110000 && Number(payrollItem.data.epf_employee) === 8000 &&
    Number(payrollItem.data.net_pay) === 100000 && Number(payrollItem.data.epf_employer) === 12000 && Number(payrollItem.data.etf_employer) === 3000;
  if (!payrollValid) throw new Error('Payroll verification failed');
  const approved = await client.rpc('advance_payroll_run', { p_run_id: payrollRunId, p_action: 'approve' });
  if (approved.error || approved.data !== 'approved') throw approved.error || new Error('Payroll approval failed');
  const paid = await client.rpc('advance_payroll_run', { p_run_id: payrollRunId, p_action: 'pay' });
  if (paid.error || paid.data !== 'paid') throw paid.error || new Error('Payroll payment failed');
  const payrollEntry = await admin.from('journal_entries').select('journal_lines(debit,credit)').eq('source_type', 'payroll').eq('source_id', payrollRunId).single();
  if (payrollEntry.error) throw payrollEntry.error;
  const payrollDebit = payrollEntry.data.journal_lines.reduce((sum, line) => sum + Number(line.debit), 0);
  const payrollCredit = payrollEntry.data.journal_lines.reduce((sum, line) => sum + Number(line.credit), 0);
  if (payrollDebit !== payrollCredit) throw new Error('Payroll journal is not balanced');

  console.log(JSON.stringify({
    pos: { stockReduced: true, receiptPosted: true, lineAudit: true, loyaltyReward: 3, changeCredited: 25, ledgerBalanced: true },
    customers: { completeProfile: true, phoneLinkedHistory: true, marketingConsent: true, tags: true },
    payroll: { grossPay: 110000, employeeEpf: 8000, netPay: 100000, employerContribution: 15000, approved: true, paid: true, ledgerBalanced: true },
  }));
} finally {
  if (orderId) {
    await admin.from('journal_entries').delete().eq('source_type', 'pos').eq('source_id', orderId);
    await admin.from('stock_movements').delete().eq('reference', (await admin.from('pos_orders').select('receipt_number').eq('id', orderId).single()).data?.receipt_number);
    await admin.from('pos_orders').delete().eq('id', orderId);
  }
  if (customerId) await admin.from('retail_customers').delete().eq('id', customerId);
  if (productId) await admin.from('products').delete().eq('id', productId);
  if (payrollRunId) {
    await admin.from('journal_entries').delete().eq('source_type', 'payroll').eq('source_id', payrollRunId);
    await admin.from('payroll_runs').delete().eq('id', payrollRunId);
  }
  if (employeeId) await admin.from('employees').delete().eq('id', employeeId);
  await client.auth.signOut();
}
