/**
 * Fetch product images from the web and store them locally for CLIP embedding.
 *
 * Providers (--provider flag):
 *
 *   ddg    DuckDuckGo image search — NO API KEY, NO ACCOUNT needed.
 *          Crawls DDG's image endpoint directly. ~1.5 s/product. (default)
 *
 *   off    Open Food Facts barcode lookup — NO API KEY needed.
 *          Returns the EXACT front-of-pack photo for real EAN/UPC barcodes.
 *          Only useful when products table has real registered barcodes.
 *          Falls back to ddg search if barcode not found.
 *
 *   google Google Custom Search API — free Google account, 100 queries/day.
 *          Needs GOOGLE_CSE_KEY + GOOGLE_CSE_ID in backend/.env
 *
 *   bing   Bing Image Search v7 — requires Azure account.
 *          Needs BING_IMAGE_SEARCH_KEY in backend/.env
 *
 * Usage:
 *   npm run images:fetch                              # ddg, default tenant
 *   npm run images:fetch -- --provider off            # barcode lookup first
 *   npm run images:fetch -- --tenant store-hanoi --limit 50
 *   npm run images:fetch -- --force                   # re-download existing
 */

import { Client } from 'pg';
import dotenv from 'dotenv';
import fs from 'fs';
import path from 'path';

dotenv.config();

// ── CLI args ──────────────────────────────────────────────────────────────────

const arg = (flag: string) => {
  const i = process.argv.indexOf(flag);
  return i !== -1 ? process.argv[i + 1] : undefined;
};

type Provider = 'ddg' | 'off' | 'google' | 'bing';

const PROVIDER  = (arg('--provider') ?? 'ddg') as Provider;
const TENANT_ID = arg('--tenant') ?? 'default';
const LIMIT     = arg('--limit') ? parseInt(arg('--limit')!, 10) : undefined;
const FORCE     = process.argv.includes('--force');

const UPLOADS_DIR = path.resolve(process.cwd(), 'uploads');

// Delay between API/crawl calls
const RATE_DELAY: Record<Provider, number> = {
  ddg:    1600, // be respectful to DDG (unofficial endpoint)
  off:    300,  // Open Food Facts has a generous rate limit
  google: 400,
  bing:   350,
};

const MIN_FILE_BYTES = 15_000; // reject tiny placeholder images

// ── Types ─────────────────────────────────────────────────────────────────────

interface ImageCandidate {
  url: string;
  format: string;
  width: number;
  height: number;
}

interface Product {
  id: string;
  sku: string;
  name: string;
  barcode: string;
  category_name: string;
}

// ── Provider: DuckDuckGo (no key) ─────────────────────────────────────────────
//
// How it works:
//   Step 1 — GET duckduckgo.com/?q=… to receive a session VQD token embedded
//             in the HTML. No login, no cookie jar needed beyond this request.
//   Step 2 — GET duckduckgo.com/i.js?q=…&vqd=… which returns JSON image results.
//
// Limitations:
//   - Unofficial endpoint; could change format without notice.
//   - Soft rate limit ~40 req/min; we stay at ~37/min (1.6 s delay).
//   - IP may be temporarily throttled after large batches; wait ~5 min and resume.

const DDG_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ' +
  'AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/124.0.0.0 Safari/537.36';

async function ddgSearch(query: string): Promise<ImageCandidate[]> {
  // Step 1: get VQD token
  const initRes = await fetch(
    `https://duckduckgo.com/?q=${encodeURIComponent(query)}&ia=images`,
    {
      headers: { 'User-Agent': DDG_UA, Accept: 'text/html' },
      signal: AbortSignal.timeout(10_000),
    }
  );
  if (!initRes.ok) throw new Error(`DDG init ${initRes.status}`);

  const html = await initRes.text();

  // VQD appears as:  vqd='4-abc123'  or  "vqd":"4-abc123"  in inline JS
  const vqdMatch = html.match(/vqd=["']?([0-9a-zA-Z-]+)["']?/);
  if (!vqdMatch?.[1]) {
    throw new Error(
      'DuckDuckGo: VQD token not found — DDG may have changed their page format. ' +
      'Try --provider google as a fallback.'
    );
  }
  const vqd = vqdMatch[1];

  // Step 2: image results
  const params = new URLSearchParams({
    l:   'us-en',
    o:   'json',
    q:   query,
    vqd,
    f:   ',,,size:Large,type:photo',
    p:   '1',   // safe search on
    s:   '0',   // result offset
  });

  const imgRes = await fetch(`https://duckduckgo.com/i.js?${params}`, {
    headers: {
      'User-Agent':      DDG_UA,
      Referer:           'https://duckduckgo.com/',
      Accept:            'application/json, text/javascript, */*; q=0.01',
      'X-Requested-With': 'XMLHttpRequest',
    },
    signal: AbortSignal.timeout(10_000),
  });

  if (imgRes.status === 403) {
    throw new Error('DuckDuckGo rate-limited (403). Wait 5 minutes then resume.');
  }
  if (!imgRes.ok) throw new Error(`DDG image search HTTP ${imgRes.status}`);

  const data = (await imgRes.json()) as {
    results?: { image: string; width: number; height: number }[];
  };

  return (data.results ?? []).slice(0, 10).map((r) => ({
    url:    r.image,
    format: guessFormat(r.image),
    width:  r.width  ?? 0,
    height: r.height ?? 0,
  }));
}

// ── Provider: Open Food Facts (barcode, no key) ────────────────────────────────
//
// Returns the exact registered front-of-pack product photo.
// Works only for real EAN-13 / UPC-A barcodes in their database.
// On miss: falls back to ddgSearch so every product gets an image.

async function offSearch(barcode: string, fallbackQuery: string): Promise<ImageCandidate[]> {
  const res = await fetch(
    `https://world.openfoodfacts.org/api/v2/product/${barcode}` +
    `?fields=image_front_url,image_url,product_name`,
    { signal: AbortSignal.timeout(8_000) }
  );

  if (res.ok) {
    const data = (await res.json()) as {
      status: number;
      product?: { image_front_url?: string; image_url?: string };
    };

    if (data.status === 1) {
      const url = data.product?.image_front_url ?? data.product?.image_url;
      if (url) {
        return [{ url, format: guessFormat(url), width: 0, height: 0 }];
      }
    }
  }

  // Barcode not in database — fall back to DDG name search
  return ddgSearch(fallbackQuery);
}

// ── Provider: Google Custom Search ────────────────────────────────────────────
//
// Setup (5 min, free, no credit card):
//   1. https://programmablesearchengine.google.com/ → New search engine
//      Enable "Search entire web" + "Image search" (Settings → Basic)
//   2. https://console.cloud.google.com/ → APIs & Services
//      Enable "Custom Search API" → Credentials → Create API key
//   3. Add to backend/.env:
//        GOOGLE_CSE_KEY=AIza...
//        GOOGLE_CSE_ID=a1b2c3...
//   Quota: 100 free queries/day

async function googleSearch(query: string): Promise<ImageCandidate[]> {
  const key = process.env.GOOGLE_CSE_KEY ?? '';
  const cx  = process.env.GOOGLE_CSE_ID  ?? '';

  if (!key || !cx) {
    throw new Error(
      'GOOGLE_CSE_KEY or GOOGLE_CSE_ID missing in backend/.env\n' +
      '  See setup comments in fetch_product_images.ts or use --provider ddg'
    );
  }

  const params = new URLSearchParams({
    key, cx,
    q:            `${query} product`,
    searchType:   'image',
    imgType:      'photo',
    imgSize:      'large',
    imgColorType: 'color',
    safe:         'active',
    num:          '8',
  });

  const res = await fetch(
    `https://www.googleapis.com/customsearch/v1?${params}`,
    { signal: AbortSignal.timeout(8_000) }
  );

  if (res.status === 429) throw new Error('Google CSE daily quota exceeded (100/day free)');
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as { error?: { message?: string } };
    throw new Error(`Google CSE ${res.status}: ${body?.error?.message ?? res.statusText}`);
  }

  const data = (await res.json()) as {
    items?: { link: string; mime: string; image: { width: number; height: number } }[];
  };

  return (data.items ?? []).map((item) => ({
    url:    item.link,
    format: item.mime?.replace('image/', '') ?? '',
    width:  item.image?.width  ?? 0,
    height: item.image?.height ?? 0,
  }));
}

// ── Provider: Bing ────────────────────────────────────────────────────────────

async function bingSearch(query: string): Promise<ImageCandidate[]> {
  const key = process.env.BING_IMAGE_SEARCH_KEY ?? '';
  if (!key) throw new Error('BING_IMAGE_SEARCH_KEY missing in backend/.env');

  const params = new URLSearchParams({
    q:          `"${query}" product`,
    count:      '8',
    imageType:  'Photo',
    minWidth:   '400',
    minHeight:  '400',
    safeSearch: 'Strict',
  });

  const res = await fetch(
    `https://api.bing.microsoft.com/v7.0/images/search?${params}`,
    {
      headers: { 'Ocp-Apim-Subscription-Key': key },
      signal: AbortSignal.timeout(8_000),
    }
  );

  if (res.status === 401) throw new Error('Invalid BING_IMAGE_SEARCH_KEY');
  if (res.status === 429) throw new Error('Bing rate limit hit');
  if (!res.ok) throw new Error(`Bing API ${res.status}`);

  const data = (await res.json()) as {
    value: { contentUrl: string; encodingFormat: string; width: number; height: number }[];
  };

  return (data.value ?? []).map((img) => ({
    url:    img.contentUrl,
    format: img.encodingFormat?.toLowerCase() ?? '',
    width:  img.width  ?? 0,
    height: img.height ?? 0,
  }));
}

// ── Router ────────────────────────────────────────────────────────────────────

async function searchImages(product: Product): Promise<ImageCandidate[]> {
  const nameQuery = `${product.name} ${product.category_name}`;

  switch (PROVIDER) {
    case 'ddg':    return ddgSearch(nameQuery);
    case 'off':    return offSearch(product.barcode, nameQuery);
    case 'google': return googleSearch(nameQuery);
    case 'bing':   return bingSearch(nameQuery);
  }
}

// ── Image download ────────────────────────────────────────────────────────────

async function downloadImage(url: string, destPath: string): Promise<boolean> {
  let res: Response;
  try {
    res = await fetch(url, { signal: AbortSignal.timeout(15_000) });
  } catch {
    return false;
  }

  if (!res.ok) return false;
  const ct = res.headers.get('content-type') ?? '';
  if (!ct.startsWith('image/')) return false;
  if (ct.includes('gif') || ct.includes('svg')) return false;

  const buf = await res.arrayBuffer();
  if (buf.byteLength < MIN_FILE_BYTES) return false;

  await fs.promises.writeFile(destPath, Buffer.from(buf));
  return true;
}

// Tries candidates sorted by format quality; returns true on first save.
async function fetchBestImage(candidates: ImageCandidate[], destPath: string): Promise<boolean> {
  const sorted = [...candidates].sort((a, b) => {
    const rank = (f: string) => (f === 'jpeg' || f === 'jpg' ? 0 : f === 'png' ? 1 : 2);
    return rank(a.format) - rank(b.format);
  });

  for (const img of sorted) {
    try {
      if (await downloadImage(img.url, destPath)) return true;
    } catch { /* try next */ }
  }
  return false;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

function guessFormat(url: string): string {
  const ext = url.split('?')[0].split('.').pop()?.toLowerCase() ?? '';
  return ['jpeg', 'jpg', 'png', 'webp'].includes(ext) ? ext : 'jpeg';
}

let lastLine = '';
function printProgress(
  current: number, total: number,
  ok: number, cached: number, failed: number,
  sku: string, status: string
) {
  const pct  = Math.round((current / total) * 100);
  const fill = Math.floor(pct / 5);
  const bar  = '█'.repeat(fill) + '░'.repeat(20 - fill);
  const line = `[${bar}] ${pct}%  ${current}/${total}  ✓${ok} ↷${cached} ✗${failed}  ${sku}: ${status}`;
  if (lastLine) process.stdout.write('\r' + ' '.repeat(lastLine.length) + '\r');
  process.stdout.write(line);
  lastLine = line;
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function run() {
  fs.mkdirSync(UPLOADS_DIR, { recursive: true });

  const db = new Client({
    connectionString:
      process.env.DATABASE_URL ??
      'postgres://shop_admin:LocalShopSecretPassword123!@localhost:5432/retail_store',
  });
  await db.connect();

  const { rows: products } = await db.query<Product>(
    `SELECT p.id, p.sku, p.name, p.barcode, c.name AS category_name
     FROM products p
     LEFT JOIN categories c ON c.id = p.category_id
     WHERE p.tenant_id = $1
       AND p.is_deleted = FALSE
     ORDER BY p.sku
     ${LIMIT ? `LIMIT ${LIMIT}` : ''}`,
    [TENANT_ID]
  );

  const total = products.length;
  console.log('\n═══════════════════════════════════════════');
  console.log(`  Provider : ${PROVIDER}${PROVIDER === 'ddg' ? '  (no API key needed)' : ''}`);
  console.log(`  Tenant   : ${TENANT_ID}`);
  console.log(`  Products : ${total}${LIMIT ? ` (--limit ${LIMIT})` : ''}`);
  console.log(`  Output   : ${UPLOADS_DIR}`);
  if (FORCE) console.log('  Mode     : --force (re-downloading existing)');
  console.log('═══════════════════════════════════════════\n');

  let ok = 0, cached = 0, failed = 0;

  for (let i = 0; i < products.length; i++) {
    const p = products[i];
    const destPath = path.join(UPLOADS_DIR, `${p.sku}.jpg`);

    if (!FORCE && fs.existsSync(destPath)) {
      cached++;
      printProgress(i + 1, total, ok, cached, failed, p.sku, 'cached');
      continue;
    }

    try {
      const candidates = await searchImages(p);

      if (candidates.length === 0) {
        failed++;
        printProgress(i + 1, total, ok, cached, failed, p.sku, 'no results');
      } else {
        const saved = await fetchBestImage(candidates, destPath);
        if (saved) {
          await db.query(
            `UPDATE products SET image_url = $1, updated_at = NOW() WHERE id = $2`,
            [`/static/images/${p.sku}.jpg`, p.id]
          );
          ok++;
          printProgress(i + 1, total, ok, cached, failed, p.sku, 'saved');
        } else {
          failed++;
          printProgress(i + 1, total, ok, cached, failed, p.sku, 'download failed');
        }
      }
    } catch (err) {
      const msg = String(err);
      // Fatal config errors: stop immediately
      if (msg.includes('missing in backend/.env') || msg.includes('rate-limited (403)')) {
        await db.end();
        console.error(`\n\n❌  ${msg}\n`);
        process.exit(1);
      }
      failed++;
      printProgress(i + 1, total, ok, cached, failed, p.sku, msg.slice(0, 70));
    }

    await sleep(RATE_DELAY[PROVIDER]);
  }

  await db.end();

  console.log('\n\n═══════════════════════════════════════════');
  console.log(`  ✓ Saved  : ${ok}`);
  console.log(`  ↷ Cached : ${cached}`);
  console.log(`  ✗ Failed : ${failed}`);
  console.log('═══════════════════════════════════════════');
  console.log('\nNext: npm run images:embed\n');
}

run().catch((err) => {
  console.error('\n\nFatal:', err);
  process.exit(1);
});
