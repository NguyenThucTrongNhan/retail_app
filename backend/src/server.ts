import Fastify, { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import fastifyCors from '@fastify/cors';
import fastifyPostgres from '@fastify/postgres';
import fastifyStatic from '@fastify/static';
import dotenv from 'dotenv';
import fs from 'fs';
import path from 'path';

dotenv.config();

// Ensure uploads directory exists before @fastify/static registers it.
// Creates it automatically so the server starts even on a fresh clone.
const uploadsDir = path.join(process.cwd(), 'uploads');
fs.mkdirSync(uploadsDir, { recursive: true });

const fastify: FastifyInstance = Fastify({ logger: true });

fastify.register(fastifyCors, {
  origin: true,
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
});

fastify.register(fastifyPostgres, {
  connectionString:
    process.env.DATABASE_URL ||
    'postgres://shop_admin:LocalShopSecretPassword123!@localhost:5432/retail_store',
});

// C4: serve product images at GET /static/images/<filename>
// B1: process.cwd() = backend/ when `npm run dev` runs from that directory
fastify.register(fastifyStatic, {
  root: uploadsDir,
  prefix: '/static/images/',
  decorateReply: false,
});

// --- TYPE DEFINITIONS ---
interface PullQuery {
  since_version?: string;
  since_timestamp?: string;
  limit?: string;
}

interface PushProductUpdate {
  id: string;
  price?: number;
  stock_quantity?: number;
}

interface PushBody {
  client_id: string;
  changes: {
    products?: PushProductUpdate[];
  };
}

// ---------------------------------------------------------------------------
// HEALTH CHECK
// /health        — always 200 if the server process is running
// /health/db     — checks live database connectivity
// ---------------------------------------------------------------------------
fastify.get('/health', async (_req: FastifyRequest, reply: FastifyReply) => {
  return reply.status(200).send({ status: 'ok' });
});

fastify.get('/health/db', async (_req: FastifyRequest, reply: FastifyReply) => {
  try {
    await fastify.pg.query('SELECT 1');
    return reply.status(200).send({ status: 'ok', database: 'connected' });
  } catch (err) {
    fastify.log.error(err, 'Database health check failed');
    return reply.status(503).send({ status: 'error', database: 'disconnected' });
  }
});

// ---------------------------------------------------------------------------
// PULL — return records changed since mobile's last known version
// ---------------------------------------------------------------------------
fastify.get(
  '/api/v1/sync/pull',
  async (
    request: FastifyRequest<{ Querystring: PullQuery }>,
    reply: FastifyReply
  ) => {
    const sinceVersion = parseInt(request.query.since_version || '0', 10);
    const sinceTimestamp = request.query.since_timestamp || null;
    const limit = Math.min(parseInt(request.query.limit || '5000', 10), 5000);

    try {
      const { rows: seqRows } = await fastify.pg.query(
        `SELECT last_value FROM product_change_seq`
      );
      const latestVersion = parseInt(seqRows[0]?.last_value || '0', 10);

      // C8 fix: use since_timestamp for categories so the filter is accurate
      // even when product versions and category updated_at timestamps differ.
      // On initial sync (sinceVersion = 0) return all; otherwise filter by timestamp.
      const { rows: categories } = await fastify.pg.query(
        `SELECT id, name, updated_at, is_deleted
         FROM categories
         WHERE $1 = 0
            OR updated_at > $2::timestamptz`,
        [sinceVersion, sinceTimestamp ?? '1970-01-01T00:00:00Z']
      );

      const { rows: products } = await fastify.pg.query(
        `SELECT id, sku, name, category_id, price, stock_quantity, barcode,
                image_url, version, updated_at, is_deleted
         FROM products
         WHERE version > $1
         ORDER BY version ASC
         LIMIT $2`,
        [sinceVersion, limit]
      );

      const updatedProducts = products.filter((p) => !p.is_deleted);
      const deletedProductIds = products
        .filter((p) => p.is_deleted)
        .map((p) => p.id);

      return reply.status(200).send({
        sync_timestamp: new Date().toISOString(),
        latest_version: latestVersion,
        has_more: products.length === limit,
        changes: {
          categories: {
            updated: categories.filter((c) => !c.is_deleted),
            deleted_ids: categories
              .filter((c) => c.is_deleted)
              .map((c) => c.id),
          },
          products: {
            updated: updatedProducts,
            deleted_ids: deletedProductIds,
          },
        },
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to fetch delta updates' });
    }
  }
);

// ---------------------------------------------------------------------------
// PUSH — apply price/stock edits from mobile (including offline outbox flushes)
// ---------------------------------------------------------------------------
fastify.post(
  '/api/v1/sync/push',
  async (
    request: FastifyRequest<{ Body: PushBody }>,
    reply: FastifyReply
  ) => {
    const { changes } = request.body || {};
    if (!changes?.products?.length) {
      return reply.status(400).send({ error: 'No product updates in payload' });
    }

    try {
      const results = await fastify.pg.transact(async (client) => {
        const records = [];
        for (const item of changes.products!) {
          const updates: string[] = [];
          const params: unknown[] = [item.id];
          let idx = 2;

          if (item.price !== undefined) {
            updates.push(`price = $${idx++}`);
            params.push(item.price);
          }
          if (item.stock_quantity !== undefined) {
            updates.push(`stock_quantity = $${idx++}`);
            params.push(item.stock_quantity);
          }
          if (updates.length === 0) continue;

          const { rows } = await client.query(
            `UPDATE products SET ${updates.join(', ')}
             WHERE id = $1
             RETURNING id, version, updated_at;`,
            params
          );
          records.push(
            rows.length > 0
              ? {
                  id: rows[0].id,
                  status: 'applied',
                  version: parseInt(rows[0].version, 10),
                  updated_at: rows[0].updated_at,
                }
              : { id: item.id, status: 'not_found' }
          );
        }
        return records;
      });

      return reply.status(200).send({
        status: 'success',
        processed_at: new Date().toISOString(),
        results: { products: results },
        conflicts: [],
      });
    } catch (error) {
      fastify.log.error(error);
      return reply.status(500).send({ error: 'Failed to process push updates' });
    }
  }
);

// ---------------------------------------------------------------------------
// START
// ---------------------------------------------------------------------------
const start = async () => {
  const port = parseInt(process.env.PORT || '8080', 10);
  const host = process.env.HOST || '0.0.0.0';
  const dbUrl = (process.env.DATABASE_URL || 'postgres://...@localhost:5432/retail_store')
    .replace(/:([^:@]+)@/, ':***@'); // mask password in logs

  fastify.log.info(`Working directory : ${process.cwd()}`);
  fastify.log.info(`Uploads directory : ${uploadsDir}`);
  fastify.log.info(`Database URL      : ${dbUrl}`);

  try {
    await fastify.listen({ port, host });
    fastify.log.info(`Server ready      : http://${host}:${port}`);
    fastify.log.info(`Health check      : http://localhost:${port}/health`);
    fastify.log.info(`DB health check   : http://localhost:${port}/health/db`);
  } catch (err) {
    fastify.log.error(err, 'Server failed to start — check database connection and port availability');
    process.exit(1);
  }
};

start();
