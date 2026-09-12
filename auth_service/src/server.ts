import Fastify from 'fastify';
import fastifyCors from '@fastify/cors';
import dotenv from 'dotenv';
import { authRoutes } from './routes/auth.js';

dotenv.config();

const fastify = Fastify({ logger: true });

fastify.register(fastifyCors, { origin: true });

fastify.get('/health', async (_req, reply) => reply.send({ status: 'ok' }));

fastify.register(authRoutes);

const start = async () => {
  const port = parseInt(process.env.PORT || '8082', 10);
  const host = process.env.HOST || '0.0.0.0';
  try {
    await fastify.listen({ port, host });
    fastify.log.info(`Auth service ready on http://${host}:${port}`);
    fastify.log.info(`Keycloak URL: ${process.env.KEYCLOAK_URL}`);
  } catch (err) {
    fastify.log.error(err, 'Auth service failed to start');
    process.exit(1);
  }
};

start();
