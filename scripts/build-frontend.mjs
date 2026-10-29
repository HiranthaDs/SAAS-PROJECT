import { build } from 'esbuild';
import { readFile, writeFile } from 'node:fs/promises';

await build({
  entryPoints: ['dist/assets/app.js'],
  bundle: true,
  format: 'esm',
  minify: true,
  sourcemap: false,
  outfile: 'dist/assets/app.bundle.js',
});

const outputPath = 'dist/assets/app.bundle.js';
const bundle = await readFile(outputPath, 'utf8');
await writeFile(outputPath, bundle.replace(/[\t ]+$/gm, ''));

console.log('Frontend bundle written to dist/assets/app.bundle.js');
