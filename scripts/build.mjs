import { build } from 'esbuild';
import { config } from 'dotenv';

config({ path: '.env.local' });

const publicUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const publicKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

if (!publicUrl || !publicKey) {
  throw new Error('Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY');
}

await build({
  entryPoints: ['dist/assets/app.js'],
  bundle: true,
  format: 'esm',
  minify: true,
  sourcemap: false,
  outfile: 'dist/assets/app.bundle.js',
  define: {
    'process.env.NEXT_PUBLIC_SUPABASE_URL': JSON.stringify(publicUrl),
    'process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY': JSON.stringify(publicKey),
  },
});

