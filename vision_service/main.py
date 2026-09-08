"""
Retail Vision Microservice — port 8081
Provides CLIP-based image embedding and pgvector cosine similarity search.

Start: uvicorn main:app --host 0.0.0.0 --port 8081 --reload
"""

import io
import os
import time
from typing import List

# Redirect HuggingFace model cache to D: drive before importing transformers/torch.
# Default C:\Users\..\.cache\ fills up quickly with the 600 MB CLIP model.
os.environ.setdefault("HF_HOME", r"D:\hf_cache")

import psycopg2
import torch
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pgvector.psycopg2 import register_vector
from PIL import Image
from psycopg2.extras import RealDictCursor
from transformers import CLIPModel, CLIPProcessor

app = FastAPI(title="Retail Visual Search Engine")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

DB_URI = os.getenv(
    "DATABASE_URL",
    "postgres://shop_admin:LocalShopSecretPassword123!@localhost:5432/retail_store",
)

# ---------------------------------------------------------------------------
# MODEL INIT — loaded once on startup (~350 MB, ~5s on first cold start)
# ---------------------------------------------------------------------------
device = "cuda" if torch.cuda.is_available() else "cpu"
print(f"Loading CLIP model on {device}…")

_model_id = "openai/clip-vit-base-patch32"
model = CLIPModel.from_pretrained(_model_id).to(device)
processor = CLIPProcessor.from_pretrained(_model_id)
model.eval()

print("CLIP model ready.")


def get_db():
    conn = psycopg2.connect(DB_URI, cursor_factory=RealDictCursor)
    register_vector(conn)
    return conn


def embed(image: Image.Image) -> List[float]:
    """Returns a normalized 512-dimensional CLIP vector for one image."""
    inputs = processor(images=image, return_tensors="pt").to(device)
    with torch.no_grad():
        features = model.get_image_features(**inputs)
        features = features / features.norm(dim=-1, keepdim=True)
    return features.cpu().numpy()[0].tolist()


# ---------------------------------------------------------------------------
# C7: STARTUP WARMUP — run one dummy inference so the first real request
# doesn't pay the JIT / CUDA warm-up penalty (5–15 s on CPU).
# ---------------------------------------------------------------------------
@app.on_event("startup")
async def warmup():
    blank = Image.new("RGB", (224, 224), color=(128, 128, 128))
    embed(blank)
    print("CLIP warmup complete — ready to serve.")


# ---------------------------------------------------------------------------
# GET /health
# C7: health endpoint so ConfigScreen can test vision service reachability.
# ---------------------------------------------------------------------------
@app.get("/health")
async def health():
    return {
        "status": "ready",
        "device": device,
        "model": _model_id,
    }


# ---------------------------------------------------------------------------
# POST /api/v1/search/visual
# Mobile camera capture → CLIP embed → pgvector cosine search → top-K matches
# ---------------------------------------------------------------------------
@app.post("/api/v1/search/visual")
async def search_visual(file: UploadFile = File(...), top_k: int = 3):
    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(400, "Uploaded file must be an image.")

    t0 = time.time()
    try:
        image = Image.open(io.BytesIO(await file.read())).convert("RGB")
        query_vec = embed(image)

        conn = get_db()
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                    id, sku, name, price, stock_quantity, image_url,
                    1 - (image_embedding <=> %s::vector) AS confidence
                FROM products
                WHERE image_embedding IS NOT NULL
                  AND is_deleted = FALSE
                ORDER BY image_embedding <=> %s::vector ASC
                LIMIT %s;
                """,
                (query_vec, query_vec, top_k),
            )
            matches = cur.fetchall()
        conn.close()

        return {
            "status": "success",
            "search_time_ms": round((time.time() - t0) * 1000, 2),
            "matches": [dict(m) for m in matches],
        }
    except Exception as e:
        raise HTTPException(500, f"Visual search failed: {e}") from e


# ---------------------------------------------------------------------------
# POST /api/v1/products/{product_id}/embed
# Generate and store a 512-d embedding for one product's reference photo.
# Run this for each product before activating visual search.
# ---------------------------------------------------------------------------
@app.post("/api/v1/products/{product_id}/embed")
async def embed_product(product_id: str, file: UploadFile = File(...)):
    try:
        image = Image.open(io.BytesIO(await file.read())).convert("RGB")
        vector = embed(image)

        conn = get_db()
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE products
                SET image_embedding = %s::vector
                WHERE id = %s
                RETURNING id, sku, name;
                """,
                (vector, product_id),
            )
            updated = cur.fetchone()
            conn.commit()
        conn.close()

        if not updated:
            raise HTTPException(404, "Product ID not found.")

        return {
            "status": "success",
            "product": dict(updated),
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(500, str(e)) from e


# ---------------------------------------------------------------------------
# POST /api/v1/admin/create-vector-index  (C5)
# Creates the HNSW cosine index ONLY when embeddings exist.
# Call this after embedding at least 50 products.
# ---------------------------------------------------------------------------
@app.post("/api/v1/admin/create-vector-index")
async def create_vector_index():
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) AS cnt FROM products WHERE image_embedding IS NOT NULL;"
            )
            count = cur.fetchone()["cnt"]  # type: ignore[index]

            if count == 0:
                raise HTTPException(
                    400,
                    "No embeddings found. Run /embed on at least 50 products first.",
                )

            cur.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_products_image_embedding_hnsw
                ON products
                USING hnsw (image_embedding vector_cosine_ops)
                WITH (m = 16, ef_construction = 64);
                """
            )
            conn.commit()

        return {
            "status": "success",
            "message": f"HNSW index created on {count} embeddings.",
            "embedding_count": count,
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(500, str(e)) from e
    finally:
        conn.close()
