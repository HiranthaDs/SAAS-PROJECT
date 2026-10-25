import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });

const client = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_PUBLISHABLE_KEY, {
  auth: { persistSession: false },
});
const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const login = await client.auth.signInWithPassword({
  email: process.env.SUPER_ADMIN_EMAIL,
  password: process.env.SUPER_ADMIN_PASSWORD,
});
if (login.error) throw login.error;

const membership = await client.from('memberships').select('org_id').eq('user_id', login.data.user.id).limit(1).single();
if (membership.error) throw membership.error;
const orgId = membership.data.org_id;
const marker = crypto.randomUUID().replaceAll('-', '').slice(0, 10).toUpperCase();

let orderId;
let productId;
let invoiceId;
try {
  const product = await client.from('products').insert({
    org_id: orgId,
    sku: `VERIFY-${marker}`,
    name: `Verification product ${marker}`,
    category: 'Verification',
    stock: 10,
    forecast: 10,
    price: 100,
  }).select().single();
  if (product.error) throw product.error;
  productId = product.data.id;

  const order = await client.from('sales_orders').insert({
    org_id: orgId,
    number: `SO-VERIFY-${marker}`,
    customer: 'Order-to-cash verification',
    customer_email: 'verification@example.test',
    salesperson_id: login.data.user.id,
  }).select().single();
  if (order.error) throw order.error;
  orderId = order.data.id;

  const line = await client.from('sales_order_lines').insert({
    sales_order_id: orderId,
    product_id: productId,
    description: 'Verified order line',
    quantity: 2,
    unit_price: 100,
    tax_rate: 10,
  });
  if (line.error) throw line.error;

  const totals = await client.from('sales_orders').select('untaxed_amount,tax_amount,total_amount').eq('id', orderId).single();
  if (totals.error) throw totals.error;
  if (Number(totals.data.untaxed_amount) !== 200 || Number(totals.data.tax_amount) !== 20 || Number(totals.data.total_amount) !== 220) {
    throw new Error(`Incorrect order totals: ${JSON.stringify(totals.data)}`);
  }

  const confirmed = await client.rpc('confirm_sales_order', { order_id: orderId });
  if (confirmed.error) throw confirmed.error;
  invoiceId = confirmed.data;

  const [confirmedOrder, invoice, stocked, invoicePosting] = await Promise.all([
    client.from('sales_orders').select('status,invoice_id').eq('id', orderId).single(),
    client.from('invoices').select('status,total').eq('id', invoiceId).single(),
    client.from('products').select('stock,forecast').eq('id', productId).single(),
    client.from('journal_entries').select('id,journal_lines(debit,credit)').eq('source_type', 'invoice').eq('source_id', invoiceId).single(),
  ]);
  for (const result of [confirmedOrder, invoice, stocked, invoicePosting]) if (result.error) throw result.error;
  const invoiceDebit = invoicePosting.data.journal_lines.reduce((sum, row) => sum + Number(row.debit), 0);
  const invoiceCredit = invoicePosting.data.journal_lines.reduce((sum, row) => sum + Number(row.credit), 0);

  const payment = await client.rpc('record_invoice_payment', { invoice_id: invoiceId, payment_amount: 220 });
  if (payment.error) throw payment.error;
  const [paidInvoice, paymentPosting] = await Promise.all([
    client.from('invoices').select('status').eq('id', invoiceId).single(),
    client.from('journal_entries').select('journal_lines(debit,credit)').eq('id', payment.data).single(),
  ]);
  for (const result of [paidInvoice, paymentPosting]) if (result.error) throw result.error;
  const paymentDebit = paymentPosting.data.journal_lines.reduce((sum, row) => sum + Number(row.debit), 0);
  const paymentCredit = paymentPosting.data.journal_lines.reduce((sum, row) => sum + Number(row.credit), 0);

  const checks = {
    orderConfirmed: confirmedOrder.data.status === 'confirmed' && confirmedOrder.data.invoice_id === invoiceId,
    invoiceCreated: Number(invoice.data.total) === 220,
    inventoryDelivered: Number(stocked.data.stock) === 8 && Number(stocked.data.forecast) === 8,
    invoiceEntryBalanced: invoiceDebit === 220 && invoiceCredit === 220,
    invoicePaid: paidInvoice.data.status === 'Paid',
    paymentEntryBalanced: paymentDebit === 220 && paymentCredit === 220,
  };
  if (Object.values(checks).some((value) => !value)) throw new Error(`Order-to-cash verification failed: ${JSON.stringify(checks)}`);
  console.log(JSON.stringify(checks));
} finally {
  if (orderId) await admin.from('sales_orders').delete().eq('id', orderId);
  if (invoiceId) {
    await admin.from('journal_entries').delete().eq('source_id', invoiceId);
    await admin.from('invoices').delete().eq('id', invoiceId);
  }
  if (productId) {
    await admin.from('stock_movements').delete().eq('product_id', productId);
    await admin.from('products').delete().eq('id', productId);
  }
  await client.auth.signOut();
}
