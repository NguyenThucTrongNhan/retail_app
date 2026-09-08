-- =============================================================================
-- Retail Store — Local PostgreSQL Setup Script
-- =============================================================================
-- Run this script in TWO steps using psql or pgAdmin.
--
-- STEP 1: Run Part A below as the postgres superuser to create the role and DB.
-- STEP 2: Connect to the retail_store database, then run Part B.
--
-- psql quick-start (run from Windows PowerShell):
--   Step 1:  psql -U postgres -f scripts\local_db_setup.sql
--   Step 2:  psql -U shop_admin -d retail_store -f scripts\local_db_setup.sql
--
-- pgAdmin quick-start:
--   Open Query Tool connected to the postgres database → paste Part A → Execute.
--   Switch connection to retail_store database → paste Part B → Execute.
-- =============================================================================


-- =============================================================================
-- PART A — Run as postgres superuser, connected to the postgres database
-- =============================================================================

-- Create the application role (safe to re-run)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'shop_admin') THEN
    CREATE ROLE shop_admin WITH LOGIN PASSWORD 'LocalShopSecretPassword123!';
  END IF;
END
$$;

-- Create the database (psql only — pgAdmin: right-click Databases → Create)
-- If using pgAdmin, skip this line and create the database through the UI,
-- then run Part B inside that database.
SELECT 'CREATE DATABASE retail_store OWNER shop_admin'
WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = 'retail_store'
)\gexec

-- Grant all privileges
GRANT ALL PRIVILEGES ON DATABASE retail_store TO shop_admin;


-- =============================================================================
-- PART B — Run as shop_admin, connected to the retail_store database
-- =============================================================================

-- Required extensions
-- NOTE: pgvector must be installed on the local PostgreSQL instance first.
-- Download from: https://github.com/pgvector/pgvector/releases
-- Choose the build matching your PostgreSQL version (pg16).
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Global monotonic sequence for delta sync versioning
CREATE SEQUENCE IF NOT EXISTS product_change_seq START 1;

-- ---------------------------------------------------------------------------
-- Categories
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS categories (
    id          UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        VARCHAR(100) NOT NULL,
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    is_deleted  BOOLEAN      NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_categories_sync_timestamp ON categories (updated_at);

-- ---------------------------------------------------------------------------
-- Products
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS products (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    sku             VARCHAR(50)   UNIQUE NOT NULL,
    name            VARCHAR(255)  NOT NULL,
    category_id     UUID          REFERENCES categories(id) ON DELETE SET NULL,
    price           NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    stock_quantity  INT           NOT NULL DEFAULT 0,
    barcode         VARCHAR(100),
    image_url       TEXT,
    image_embedding vector(512),           -- populated by vision_service embed endpoint
    version         BIGINT        NOT NULL DEFAULT nextval('product_change_seq'),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    is_deleted      BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_products_sync_version    ON products (version);
CREATE INDEX IF NOT EXISTS idx_products_sync_timestamp  ON products (updated_at);

-- ---------------------------------------------------------------------------
-- Trigger: auto-bump updated_at and version on every product UPDATE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_product_sync_metadata()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    NEW.version    = nextval('product_change_seq');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_products_sync_metadata ON products;
CREATE TRIGGER trg_products_sync_metadata
BEFORE UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION update_product_sync_metadata();

-- ---------------------------------------------------------------------------
-- Grant table permissions to shop_admin
-- ---------------------------------------------------------------------------
GRANT ALL ON ALL TABLES    IN SCHEMA public TO shop_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO shop_admin;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO shop_admin;

-- Verify
SELECT 'Setup complete. Tables: ' || string_agg(tablename, ', ' ORDER BY tablename)
FROM pg_tables
WHERE schemaname = 'public';
