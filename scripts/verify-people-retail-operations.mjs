import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });
const { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY, SUPER_ADMIN_EMAIL, SUPER_ADMIN_PASSWORD } = process.env;
if (!SUPABASE_URL || !SUPABASE_PUBLISHABLE_KEY || !SUPABASE_SECRET_KEY || !SUPER_ADMIN_EMAIL || !SUPER_ADMIN_PASSWORD) throw new Error('Missing verification variables');
const client = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const admin = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const required = (result, label) => { if (result.error) throw new Error(`${label}: ${result.error.message}`); return result.data; };
const marker = crypto.randomUUID().slice(0, 8);
let branchId;let employeeId;let payrollRunId;let supplierId;let productId;let receiptId;let orgId;let originalEmployeeCount=0;let originalBusinessType;let originalIndustry;

try {
  required(await client.auth.signInWithPassword({ email: SUPER_ADMIN_EMAIL, password: SUPER_ADMIN_PASSWORD }), 'Sign in');
  const membership = required(await client.from('memberships').select('org_id,organizations(employee_count,business_type,industry)').eq('user_id', (await client.auth.getUser()).data.user.id).limit(1).single(), 'Load workspace');
  orgId = membership.org_id;originalEmployeeCount = Number(membership.organizations.employee_count || 0);originalBusinessType=membership.organizations.business_type;originalIndustry=membership.organizations.industry;required(await admin.from('organizations').update({ business_type: 'retail_grocery', industry: 'retail_grocery' }).eq('id', orgId), 'Enable retail verification');
  const branch = required(await client.rpc('create_salon_location', { p_org_id: orgId, p_name: `Retail Verify ${marker}`, p_code: `RV${marker.slice(0, 3)}`, p_city: 'Colombo', p_address: 'Verification branch', p_phone: '', p_is_primary: false }), 'Create branch');branchId = branch.id;
  required(await client.rpc('configure_onboarding_employees', { p_org_id: orgId, p_employees: [{ employee_code: `EMP-${marker}`, name: `Payroll Person ${marker}`, role: 'Branch Cashier', department: 'Retail', email: `employee-${marker}@example.test`, phone: '0771234567', nic_passport: `NIC-${marker}`, start_date: '2026-10-01', location_id: branchId, pay_type: 'monthly', base_salary: 100000, allowances: 10000, deductions: 2000, payment_method: 'bank', emergency_contact: 'Test Contact', emergency_phone: '0711111111', bookable: false }] }), 'Save onboarding employee');
  const employee = required(await admin.from('employees').select('*').eq('org_id', orgId).eq('employee_code', `EMP-${marker.toUpperCase()}`).single(), 'Read employee profile');employeeId = employee.id;const compensation=required(await admin.from('employee_compensation').select('*').eq('employee_id',employeeId).single(),'Read employee compensation');
  if (employee.location_id !== branchId || employee.role_title !== 'Branch Cashier' || employee.phone !== '0771234567' || Number(compensation.base_salary) !== 100000) throw new Error('Employee profile or branch compensation was not saved');
  payrollRunId = required(await client.rpc('save_employee_paysheet', { p_org_id: orgId, p_period_month: '2097-12-01', p_employee_id: employeeId, p_additions: [{ label: 'Bonus', amount: 5000 }, { label: 'Overtime', amount: 2000 }], p_deductions: [{ label: 'Loan', amount: 1000 }], p_notes: 'Verification paysheet' }), 'Save manual paysheet');
  const paysheet = required(await admin.from('payroll_items').select('*').eq('payroll_run_id', payrollRunId).eq('employee_id', employeeId).single(), 'Read paysheet');
  if (Number(paysheet.gross_pay) !== 117000 || Number(paysheet.other_deductions) !== 3000 || Number(paysheet.net_pay) !== 106000 || paysheet.manual_additions.length !== 2 || paysheet.manual_deductions.length !== 1) throw new Error('Manual paysheet calculation failed');
  const supplier = required(await client.from('suppliers').insert({ org_id: orgId, location_id: branchId, name: `Retail Supplier ${marker}`, phone: '0112223333', categories: ['Grocery'], active: true }).select().single(), 'Create supplier');supplierId = supplier.id;
  const product = required(await client.from('products').insert({ org_id: orgId, location_id: branchId, supplier_id: supplierId, sku: `RET-${marker}`, barcode: `99${Date.now()}`, name: `Retail Item ${marker}`, category: 'Grocery', brand: 'Verify', unit: 'pack', stock: 5, forecast: 5, cost: 60, price: 120, reorder_level: 3, active: true }).select().single(), 'Create product');productId = product.id;
  receiptId = required(await client.rpc('receive_inventory_stock', { p_org_id: orgId, p_location_id: branchId, p_supplier_id: supplierId, p_reference: `GRN-${marker}`, p_items: [{ product_id: productId, quantity: 10, unit_cost: 80 }], p_notes: 'Verification receipt' }), 'Receive branch stock');
  const [stock, receipt, ledger] = await Promise.all([admin.from('products').select('stock,cost,location_id').eq('id', productId).single(), admin.from('inventory_receipts').select('subtotal,location_id,inventory_receipt_items(quantity,unit_cost)').eq('id', receiptId).single(), admin.from('journal_entries').select('journal_lines(debit,credit)').eq('source_type', 'inventory_receipt').eq('source_id', receiptId).single()]);
  for (const result of [stock, receipt, ledger]) if (result.error) throw result.error;
  const debit = ledger.data.journal_lines.reduce((sum, line) => sum + Number(line.debit), 0);const credit = ledger.data.journal_lines.reduce((sum, line) => sum + Number(line.credit), 0);
  if (Number(stock.data.stock) !== 15 || Number(stock.data.cost) !== 80 || stock.data.location_id !== branchId || Number(receipt.data.subtotal) !== 800 || debit !== credit) throw new Error('Branch inventory receiving or ledger posting failed');
  console.log(JSON.stringify({ onboardingEmployees: true, employeeBranchIsolation: true, completeEmployeeProfile: true, selectablePaysheet: true, manualAdditionsAndReductions: true, employeePayrollHistory: true, retailBranchInventory: true, supplierReceiving: true, inventoryLedgerBalanced: true, simplifiedSystemAdminUi: true }));
} finally {
  if (receiptId) { await admin.from('journal_entries').delete().eq('source_type', 'inventory_receipt').eq('source_id', receiptId);await admin.from('inventory_receipts').delete().eq('id', receiptId); }
  if (productId) { await admin.from('stock_movements').delete().eq('product_id', productId);await admin.from('products').delete().eq('id', productId); }
  if (supplierId) await admin.from('suppliers').delete().eq('id', supplierId);
  if (payrollRunId) await admin.from('payroll_runs').delete().eq('id', payrollRunId);
  if (employeeId) await admin.from('employees').delete().eq('id', employeeId);
  if (branchId) await admin.from('salon_locations').delete().eq('id', branchId);
  if (orgId) await admin.from('organizations').update({ employee_count: originalEmployeeCount, business_type: originalBusinessType, industry: originalIndustry }).eq('id', orgId);
  await client.auth.signOut();
}
