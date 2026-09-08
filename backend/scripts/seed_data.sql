-- =============================================================================
-- Retail Store — Development Seed Data
-- =============================================================================
-- Run AFTER local_db_setup.sql (schema must already exist).
-- Connect as shop_admin to retail_store database, then run this file.
--
--   psql -U shop_admin -d retail_store -f scripts\seed_data.sql
--
-- Safe to re-run: uses INSERT … ON CONFLICT DO NOTHING on SKU.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Categories (5)
-- ---------------------------------------------------------------------------
INSERT INTO categories (id, name) VALUES
  ('11111111-0001-0001-0001-000000000001', 'Beverages'),
  ('11111111-0001-0001-0001-000000000002', 'Snacks & Confectionery'),
  ('11111111-0001-0001-0001-000000000003', 'Household & Cleaning'),
  ('11111111-0001-0001-0001-000000000004', 'Electronics & Accessories'),
  ('11111111-0001-0001-0001-000000000005', 'Personal Care & Hygiene')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Products (18) — version and updated_at auto-set by trigger / default
-- ---------------------------------------------------------------------------
INSERT INTO products (sku, name, category_id, price, stock_quantity, barcode)
VALUES

  -- Beverages
  ('BEV001', 'Mineral Water 500ml',       '11111111-0001-0001-0001-000000000001',  0.75, 500, '8901234500001'),
  ('BEV002', 'Coca-Cola Can 330ml',       '11111111-0001-0001-0001-000000000001',  1.20, 300, '8901234500002'),
  ('BEV003', 'Orange Juice 1L',           '11111111-0001-0001-0001-000000000001',  2.50, 150, '8901234500003'),
  ('BEV004', 'Coffee Latte 250ml',        '11111111-0001-0001-0001-000000000001',  1.80, 200, '8901234500004'),

  -- Snacks
  ('SNK001', 'Potato Chips Original 150g','11111111-0001-0001-0001-000000000002',  1.50, 200, '8901234500005'),
  ('SNK002', 'Dark Chocolate Bar 100g',   '11111111-0001-0001-0001-000000000002',  2.00, 150, '8901234500006'),
  ('SNK003', 'Salted Crackers 200g',      '11111111-0001-0001-0001-000000000002',  1.25, 180, '8901234500007'),
  ('SNK004', 'Assorted Cookies 250g',     '11111111-0001-0001-0001-000000000002',  3.50, 120, '8901234500008'),

  -- Household
  ('HSH001', 'Laundry Detergent 1kg',     '11111111-0001-0001-0001-000000000003',  5.99,  80, '8901234500009'),
  ('HSH002', 'Dish Soap 500ml',           '11111111-0001-0001-0001-000000000003',  2.75, 120, '8901234500010'),
  ('HSH003', 'Paper Towels 4-Roll Pack',  '11111111-0001-0001-0001-000000000003',  3.25, 100, '8901234500011'),

  -- Electronics
  ('ELC001', 'USB-C Cable 1m',            '11111111-0001-0001-0001-000000000004',  8.99,  50, '8901234500012'),
  ('ELC002', 'Phone Charger 20W',         '11111111-0001-0001-0001-000000000004', 15.99,  40, '8901234500013'),
  ('ELC003', 'AA Batteries 4-pack',       '11111111-0001-0001-0001-000000000004',  4.50, 200, '8901234500014'),

  -- Personal Care
  ('PRS001', 'Shampoo 400ml',             '11111111-0001-0001-0001-000000000005',  6.99,  90, '8901234500015'),
  ('PRS002', 'Toothpaste 150g',           '11111111-0001-0001-0001-000000000005',  3.49, 150, '8901234500016'),
  ('PRS003', 'Hand Soap 250ml',           '11111111-0001-0001-0001-000000000005',  2.99, 130, '8901234500017'),
  ('PRS004', 'Sunscreen SPF50 100ml',     '11111111-0001-0001-0001-000000000005', 12.50,  60, '8901234500018')

ON CONFLICT (sku) DO NOTHING;

-- Verify
SELECT
  c.name AS category,
  COUNT(p.id) AS product_count
FROM categories c
LEFT JOIN products p ON p.category_id = c.id AND p.is_deleted = FALSE
GROUP BY c.name
ORDER BY c.name;
