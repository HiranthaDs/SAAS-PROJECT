import { config } from 'dotenv';
import { createClient } from '@supabase/supabase-js';

config({ path: '.env.local' });
const client = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const marker = crypto.randomUUID().slice(0, 8);
const email = `notification-system-${marker}@example.test`;
const password = `Notice-${crypto.randomUUID()}!`;
const created = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { full_name: 'Notification Verifier', company_name: `Notification Workspace ${marker}`, provisioning_kind: 'workspace_owner' } });
if (created.error) throw created.error;
const userId = created.data.user.id;
const membership = await admin.from('memberships').select('org_id').eq('user_id', userId).single();
if (membership.error) throw membership.error;
await admin.from('profiles').update({ platform_role: 'system_admin' }).eq('id', userId);
const login = await client.auth.signInWithPassword({ email, password });
if (login.error) throw login.error;
let notificationId;
try {
  const sent = await client.rpc('send_system_notification', { p_org_id: membership.data.org_id, p_title: 'Verification notice', p_body: 'Notification delivery verification.', p_severity: 'warning', p_expires_at: null });
  if (sent.error) throw sent.error;
  notificationId = sent.data.id;
  const inbox = await client.rpc('get_my_system_notifications');
  if (inbox.error) throw inbox.error;
  const notice = inbox.data.find((item) => item.id === notificationId);
  if (!notice || notice.read || notice.severity !== 'warning') throw new Error('Notification was not delivered unread');
  const marked = await client.rpc('mark_system_notification_read', { p_notification_id: notificationId });
  if (marked.error || marked.data !== true) throw marked.error || new Error('Notification read state failed');
  const refreshed = await client.rpc('get_my_system_notifications');
  if (refreshed.error || !refreshed.data.find((item) => item.id === notificationId)?.read) throw refreshed.error || new Error('Notification read state was not stored');
  console.log(JSON.stringify({ systemAdminSend: true, workspaceDelivery: true, priorityPreserved: true, readTracking: true }));
} finally {
  if (notificationId) await admin.from('system_notifications').delete().eq('id', notificationId);
  await client.auth.signOut();
  await admin.from('organizations').delete().eq('id', membership.data.org_id);
  await admin.auth.admin.deleteUser(userId);
}
