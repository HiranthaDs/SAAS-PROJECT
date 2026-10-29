import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile('dist/assets/app.js', 'utf8');
const migration = await readFile('supabase/migrations/020_ten_isolated_industry_modules.sql', 'utf8');

const industries = {
  clothing_fashion: 'fashion_operations',
  restaurant: 'restaurant_operations',
  hotel: 'hotel_operations',
  construction: 'construction_operations',
  real_estate: 'real_estate_operations',
  education: 'education_operations',
  healthcare_clinic: 'clinic_operations',
  logistics: 'logistics_operations',
  manufacturing_business: 'manufacturing_operations',
  agriculture: 'agriculture_operations',
};

for (const [businessType, moduleKey] of Object.entries(industries)) {
  assert.match(source, new RegExp(`\\b${businessType}:\\{`), `${businessType} profile is missing`);
  assert.match(source, new RegExp(`key:'${moduleKey}'`), `${businessType} UI module key is missing`);
  assert.match(migration, new RegExp(`when '${businessType}' then '${moduleKey}'`), `${businessType} database isolation mapping is missing`);
}

assert.equal(new Set(Object.values(industries)).size, 10, 'Every new industry must have a unique module key');
assert.match(source, /function industryOperations\(\)/, 'Dedicated industry workspace renderer is missing');
assert.match(source, /function industrySettingsPanel\(\)/, 'Industry settings panel is missing');
assert.match(migration, /enforce_industry_module_isolation/, 'Database isolation trigger is missing');
assert.match(migration, /advance_industry_record/, 'Industry workflow transition function is missing');
assert.match(migration, /business_type_uses_locations/, 'Shared multi-location support is missing');
assert.match(migration, /Active location-enabled workspace not found/, 'Location creation was not generalized for the new industries');

console.log(JSON.stringify({ industries: Object.keys(industries).length, uniqueModuleKeys: true, configuration: true, workflowIsolation: true }));
