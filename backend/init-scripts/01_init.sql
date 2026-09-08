-- Retail Store — PostgreSQL initialization script
-- Runs automatically on first Docker container start.
--
-- C5 NOTE: The HNSW vector index is NOT created here because building it on an
-- empty image_embedding column wastes memory and produces no benefit.
-- Run backend/scripts/create_vector_index.sql AFTER the embedding pipeline has
-- processed at least 50 product reference photos.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Global monotonic sequence for delta sync versioning
CREATE SEQUENCE IF NOT EXISTS product_change_seq START 1;

-- Categories
CREATE TABLE IF NOT EXISTS categories (
    id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        VARCHAR(100) NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_deleted  BOOLEAN     NOT NULL DEFAULT FALSE
);

-- Products (with 512-dimension vector slot for Phase 3 visual search)
CREATE TABLE IF NOT EXISTS products (
    id              UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    sku             VARCHAR(50)  UNIQUE NOT NULL,
    name            VARCHAR(255) NOT NULL,
    category_id     UUID         REFERENCES categories(id) ON DELETE SET NULL,
    price           NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    stock_quantity  INT          NOT NULL DEFAULT 0,
    barcode         VARCHAR(100),
    image_url       TEXT,
    image_embedding vector(512),          -- populated by vision_service embed endpoint
    version         BIGINT       NOT NULL DEFAULT nextval('product_change_seq'),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    is_deleted      BOOLEAN      NOT NULL DEFAULT FALSE
);

-- Indexes for sub-millisecond delta sync queries
CREATE INDEX IF NOT EXISTS idx_products_sync_version   ON products (version);
CREATE INDEX IF NOT EXISTS idx_products_sync_timestamp ON products (updated_at);
CREATE INDEX IF NOT EXISTS idx_categories_sync_timestamp ON categories (updated_at);

-- Auto-bump updated_at and version on every UPDATE
CREATE OR REPLACE FUNCTION update_product_sync_metadata()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    NEW.version    = nextval('product_change_seq');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_products_sync_metadata
BEFORE UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION update_product_sync_metadata();
