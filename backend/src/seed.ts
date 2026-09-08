import { Client } from 'pg';
import dotenv from 'dotenv';

dotenv.config();

const client = new Client({
  connectionString:
    process.env.DATABASE_URL ||
    'postgres://shop_admin:LocalShopSecretPassword123!@localhost:5432/retail_store',
});

const CATEGORIES = [
  'Beverages & Soft Drinks',
  'Snacks & Confectionery',
  'Dairy & Refrigerated',
  'Bakery & Fresh Bread',
  'Canned & Packaged Goods',
  'Personal Care & Hygiene',
  'Household Supplies',
  'Frozen Foods',
];

const BRANDS = [
  'PureLife', 'SunHarvest', 'GoldenCrunch', 'FreshDairy',
  'DailyClean', 'EcoGreen', 'BakeHouse', 'SnackTime', 'Vitality', 'CozyHome',
];

const PRODUCT_TYPES = [
  'Sparkling Water 500ml', 'Whole Milk 1L', 'Potato Chips Salted 150g',
  'Organic Eggs 12pk', 'Dark Chocolate 100g', 'Dishwashing Liquid 750ml',
  'Laundry Detergent 2L', 'Whole Wheat Bread 400g', 'Instant Coffee 200g',
  'Green Tea 25 Bags', 'Paper Towels 2 Rolls', 'Hand Soap Lavender 250ml',
  'Orange Juice 1L', 'Canned Tuna 185g', 'Pasta Spaghetti 500g',
];

const pick = <T>(arr: T[]): T => arr[Math.floor(Math.random() * arr.length)];

const barcode = (i: number) => `893${String(i).padStart(9, '0')}`;

async function seed() {
  console.log('Starting 5,000 product seed…\n');
  const t = Date.now();

  try {
    await client.connect();
    await client.query('BEGIN');

    console.log('Clearing existing data…');
    await client.query('TRUNCATE TABLE products, categories RESTART IDENTITY CASCADE;');

    console.log('Inserting categories…');
    const catIds: string[] = [];
    for (const name of CATEGORIES) {
      const { rows } = await client.query(
        'INSERT INTO categories (name) VALUES ($1) RETURNING id;',
        [name]
      );
      catIds.push(rows[0].id);
    }

    const total = 5000;
    const batch = 500;
    console.log(`Inserting ${total} products in batches of ${batch}…`);

    for (let i = 0; i < total; i += batch) {
      const values: unknown[] = [];
      const tuples: string[] = [];
      let p = 1;

      for (let j = 0; j < batch && i + j < total; j++) {
        const n = i + j + 1;
        tuples.push(`($${p++},$${p++},$${p++},$${p++},$${p++},$${p++},$${p++})`);
        values.push(
          `SKU-${String(n).padStart(5, '0')}`,
          `${pick(BRANDS)} ${pick(PRODUCT_TYPES)} #${n}`,
          pick(catIds),
          (Math.random() * 48 + 0.99).toFixed(2),
          Math.floor(Math.random() * 150) + 5,
          barcode(n),
          `http://localhost:8080/static/images/SKU-${String(n).padStart(5, '0')}.jpg`
        );
      }

      await client.query(
        `INSERT INTO products (sku, name, category_id, price, stock_quantity, barcode, image_url)
         VALUES ${tuples.join(', ')};`,
        values
      );
      console.log(`  ✓ ${i + 1} – ${Math.min(i + batch, total)}`);
    }

    await client.query('COMMIT');
    console.log(`\nDone — ${total} products in ${((Date.now() - t) / 1000).toFixed(2)}s`);
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('Seed failed — rolled back.', err);
    process.exit(1);
  } finally {
    await client.end();
  }
}

seed();
