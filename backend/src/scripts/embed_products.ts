/**
 * Trigger the vision service to compute CLIP embeddings for every product
 * that has a locally-stored image but no embedding yet.
 *
 * Run AFTER images:fetch. This populates image_embedding so lens search works.
 *
 * Usage:
 *   npm run images:embed
 *   npm run images:embed -- --tenant store-hanoi --limit 100
 *   npm run images:embed -- --force   # re-embed even if embedding exists
 *
 * Requires the vision service to be running on VISION_SERVICE_URL (default: http://localhost:8081)
 */

import { Client } from 'pg';
import dotenv from 'dotenv';
import fs from 'fs';
import path from 'path';

dotenv.config();

// ── Config ────────────────────────────────────────────────────────────────────

const VISION_URL = (process.env.VISION_SERVICE_URL ?? 'http://localhost:8081').replace(/\/$/, '');

const tenantArg = process.argv.indexOf('--tenant');
const TENANT_ID = tenantArg !== -1 ? process.argv[tenantArg + 1] : 'default';

const limitArg = process.argv.indexOf('--limit');
const LIMIT = limitArg !== -1 ? parseInt(process.argv[limitArg + 1], 10) : undefined;

const FORCE = process.argv.includes('--force');

// Delay between embed calls — vision service is CPU/GPU bound, give it breathing room
const RATE_DELAY_MS = 200;

const UPLOADS_DIR = path.resolve(process.cwd(), 'uploads');

// ── Main ──────────────────────────────────────────────────────────────────────

async function run() {
  // Verify vision service is up before starting
  try {
    const health = await fetch(`${VISION_URL}/health`, { signal: AbortSignal.timeout(5_000) });
    if (!health.ok) throw new Error(`HTTP ${health.status}`);
    console.log(`Vision service reachable at ${VISION_URL}`);
  } catch (err) {
    console.error(`\n❌  Vision service not reachable at ${VISION_URL}: ${err}`);
    console.error('    Start it first: cd vision_service && python main.py\n');
    process.exit(1);
  }

  const db = new Client({
    connectionString:
      process.env.DATABASE_URL ??
      'postgres://shop_admin:LocalShopSecretPassword123!@localhost:5432/retail_store',
  });
  await db.connect();

  const embedFilter = FORCE
    ? 'TRUE'
    : 'p.image_embedding IS NULL';

  const { rows: products } = await db.query<{ id: string; sku: string; name: string }>(
    `SELECT p.id, p.sku, p.name
     FROM products p
     WHERE p.tenant_id = $1
       AND p.is_deleted = FALSE
       AND ${embedFilter}
     ORDER BY p.sku
     ${LIMIT ? `LIMIT ${LIMIT}` : ''}`,
    [TENANT_ID]
  );

  // Filter down to products that actually have a local image file
  const withImage = products.filter((p) =>
    fs.existsSync(path.join(UPLOADS_DIR, `${p.sku}.jpg`))
  );

  const total = withImage.length;
  const skippedNoImage = products.length - withImage.length;

  console.log(`\nEmbedding ${total} products (tenant: ${TENANT_ID})`);
  if (skippedNoImage > 0)
    console.log(`  ${skippedNoImage} skipped — no local image file (run images:fetch first)`);
  console.log();

  let done = 0;
  let failed = 0;

  for (let i = 0; i < withImage.length; i++) {
    const product = withImage[i];

    try {
      const res = await fetch(`${VISION_URL}/api/v1/products/${product.id}/embed`, {
        method: 'POST',
        signal: AbortSignal.timeout(30_000), // CLIP inference can be slow on CPU
      });

      if (res.ok) {
        done++;
        printProgress(i + 1, total, done, failed, product.sku, 'embedded');
      } else {
        const body = await res.text().catch(() => '');
        failed++;
        printProgress(i + 1, total, done, failed, product.sku, `HTTP ${res.status} ${body.slice(0, 60)}`);
      }
    } catch (err) {
      failed++;
      printProgress(i + 1, total, done, failed, product.sku, String(err));
    }

    await sleep(RATE_DELAY_MS);
  }

  await db.end();

  console.log('\n');
  console.log('═══════════════════════════════════════════');
  console.log(`  Embedding complete for tenant "${TENANT_ID}"`);
  console.log(`  ✓ Embedded : ${done}`);
  console.log(`  ✗ Failed   : ${failed}`);
  console.log('═══════════════════════════════════════════');

  if (done > 50) {
    console.log('\nNext step: build the HNSW vector index for fast search:');
    console.log(`  curl -X POST ${VISION_URL}/api/v1/admin/create-vector-index\n`);
  } else {
    console.log(`\nNote: HNSW index requires 50+ embeddings (have ${done}).`);
    console.log('  Add more products/embeddings then run:');
    console.log(`  curl -X POST ${VISION_URL}/api/v1/admin/create-vector-index\n`);
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

let lastLine = '';
function printProgress(
  current: number,
  total: number,
  done: number,
  failed: number,
  sku: string,
  status: string
) {
  const pct = Math.round((current / total) * 100);
  const bar = '█'.repeat(Math.floor(pct / 5)) + '░'.repeat(20 - Math.floor(pct / 5));
  const line = `[${bar}] ${pct}%  ${current}/${total}  ✓${done} ✗${failed}  ${sku}: ${status}`;

  if (lastLine.length > 0) process.stdout.write('\r' + ' '.repeat(lastLine.length) + '\r');
  process.stdout.write(line);
  lastLine = line;
}

run().catch((err) => {
  console.error('\n\nFatal error:', err);
  process.exit(1);
});
