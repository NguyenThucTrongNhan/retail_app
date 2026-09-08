-- ============================================================
-- HNSW Vector Index — run this AFTER embedding reference photos
-- ============================================================
--
-- HOW TO RUN:
--   Option A (psql inside WSL):
--     psql postgres://shop_admin:LocalShopSecretPassword123!@localhost:5432/retail_store \
--          -f /mnt/d/projects/retail_app/backend/scripts/create_vector_index.sql
--
--   Option B (DBeaver): open this file and execute.
--
--   Option C (vision_service admin endpoint):
--     curl -X POST http://localhost:8081/api/v1/admin/create-vector-index
--
-- PREREQUISITE:
--   At least 50 products must have image_embedding populated.
--   Check: SELECT COUNT(*) FROM products WHERE image_embedding IS NOT NULL;
-- ============================================================

DO $$
DECLARE
  embedding_count INT;
BEGIN
  SELECT COUNT(*) INTO embedding_count
  FROM products
  WHERE image_embedding IS NOT NULL;

  IF embedding_count = 0 THEN
    RAISE EXCEPTION
      'No embeddings found. Run the vision_service embed endpoint for at least '
      '50 products before creating the HNSW index.';
  END IF;

  IF embedding_count < 50 THEN
    RAISE WARNING
      'Only % embeddings found. HNSW index accuracy improves with more vectors. '
      'Consider embedding more products first.', embedding_count;
  END IF;

  -- HNSW (Hierarchical Navigable Small World) gives ~2–5ms cosine search
  -- for up to 100k vectors — no retraining needed when new embeddings are added.
  CREATE INDEX IF NOT EXISTS idx_products_image_embedding_hnsw
  ON products
  USING hnsw (image_embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

  RAISE NOTICE 'HNSW index created on % product embeddings.', embedding_count;
END $$;
