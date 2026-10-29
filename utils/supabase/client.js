import { createClient as createSupabaseClient } from '@supabase/supabase-js';

const runtimeConfig = globalThis.__NEXORA_CONFIG__ || {};
const supabaseUrl = runtimeConfig.supabaseUrl;
const supabaseKey = runtimeConfig.supabasePublishableKey;

if (!supabaseUrl || !supabaseKey) {
  throw new Error('Supabase public configuration is missing. Set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY.');
}

export const supabase = createSupabaseClient(supabaseUrl, supabaseKey, {
  auth: {
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: true,
    storage: typeof window !== 'undefined' ? window.localStorage : undefined,
  },
});

