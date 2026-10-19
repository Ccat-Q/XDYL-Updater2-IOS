import { ApiError, fail, response } from './common.js';
import { v2 } from './v2.js';
import { legacy } from './legacy.js';
import { drainBark, cleanup } from './bark.js';
import { sweepRecovery } from './recovery.js';

export const routes = [
  [/^\/chat\/ping$/, ['GET']], [/^\/chat\/key$/, ['POST']], [/^\/chat\/key\/[^/]+$/, ['GET']],
  [/^\/chat\/send$/, ['POST']], [/^\/chat\/pull$/, ['GET']], [/^\/chat\/read$/, ['GET', 'POST']],
  [/^\/chat\/v2\/capabilities$/, ['GET']], [/^\/chat\/v2\/session$/, ['POST', 'DELETE']],
  [/^\/chat\/v2\/devices$/, ['GET']], [/^\/chat\/v2\/devices\/[^/]+$/, ['DELETE']],
  [/^\/chat\/v2\/devices\/[^/]+\/keys$/, ['POST']], [/^\/chat\/v2\/users\/[^/]+\/keys$/, ['GET']],
  [/^\/chat\/v2\/messages$/, ['POST']], [/^\/chat\/v2\/sync$/, ['GET']],
  [/^\/chat\/v2\/sync\/(ack|reset)$/, ['POST']], [/^\/chat\/v2\/conversations\/[^/]+\/read$/, ['POST']],
  [/^\/chat\/v2\/devices\/[^/]+\/bark$/, ['GET','PUT', 'DELETE']],
  [/^\/chat\/v2\/devices\/[^/]+\/bark\/test$/, ['POST']],
  [/^\/chat\/v2\/devices\/[^/]+\/bark\/status$/, ['GET']]
  ,[/^\/chat\/v2\/devices\/[^/]+\/legacy$/, ['GET','POST']]
  ,[/^\/chat\/v2\/users\/[^/]+\/protocols$/, ['GET']]
  ,[/^\/chat\/v2\/legacy\/messages$/, ['POST']]
  ,[/^\/chat\/v2\/me\/preferences$/, ['GET','PATCH']]
  ,[/^\/chat\/v2\/blocks$/, ['GET']]
  ,[/^\/chat\/v2\/blocks\/[^/]+$/, ['PUT','DELETE']]
  ,[/^\/chat\/v2\/conversations$/, ['GET']]
  ,[/^\/chat\/v2\/conversations\/[^/]+\/state$/, ['GET','PATCH']]
  ,[/^\/chat\/v2\/conversations\/[^/]+\/clear$/, ['POST']]
  ,[/^\/chat\/v2\/conversations\/[^/]+\/messages$/, ['GET']]
  ,[/^\/chat\/v2\/messages\/[^/]+$/, ['DELETE']]
  ,[/^\/chat\/v2\/messages\/[^/]+\/recall$/, ['POST']]
  ,[/^\/chat\/v2\/(me|devices\/[^/]+)(\/conversations\/[^/]+)?\/notifications$/, ['GET','PATCH']]
  ,[/^\/chat\/v2\/history\/(quota|filters)$/, ['GET']]
  ,[/^\/chat\/v2\/history\/(backups|transfers)$/, ['GET','POST']]
  ,[/^\/chat\/v2\/history\/(backups|transfers)\/[^/]+$/, ['GET','DELETE']]
  ,[/^\/chat\/v2\/history\/transfers\/[^/]+\/approve$/, ['POST']]
  ,[/^\/chat\/v2\/history\/(backups|transfers)\/[^/]+\/complete$/, ['POST']]
  ,[/^\/chat\/v2\/history\/transfers\/[^/]+\/ack$/, ['POST']]
  ,[/^\/chat\/v2\/history\/(backups|transfers)\/[^/]+\/chunks\/[0-9]+$/, ['GET','PUT']]
];
export function createWorker(overrides = {}) {
  const deps = { fetch: (...args) => fetch(...args), now: () => Date.now(), random: () => Math.random(), ...overrides };
  return {
    async fetch(req, env, ctx) {
      const requestId = crypto.randomUUID(); const url = new URL(req.url); const modern = url.pathname.startsWith('/chat/v2/');
      try {
        if (url.protocol !== 'https:') fail(400, 'HTTPS_REQUIRED');
        if (url.username || url.password || url.searchParams.has('token')) fail(400, 'INVALID_REQUEST');
        const route = routes.find(([pattern]) => pattern.test(url.pathname));
        if (!route) fail(404, 'NOT_FOUND');
        if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: {
          'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': [...route[1], 'OPTIONS'].join(','),
          'Access-Control-Allow-Headers': 'Authorization,Content-Type,X-Chunk-SHA256', 'Cache-Control': 'no-store'
        } });
        if (!route[1].includes(req.method)) throw new ApiError(405, 'METHOD_NOT_ALLOWED', undefined, { Allow: route[1].join(',') });
        if (!env.DB?.prepare) fail(503, 'NOT_CONFIGURED');
        // Every request starts on primary; subsequent reads carry the D1 bookmark.
        const db = env.DB.withSession ? env.DB.withSession('first-primary') : env.DB;
        const data = modern ? await v2(req, env, db, url, deps) : await legacy(req, env, db, url, deps);
        if (ctx?.waitUntil && req.method === 'POST' && /\/(messages|test|send)$/.test(url.pathname)) {
          ctx.waitUntil(drainBark(env, db, deps, 2).catch(() => {}));
        }
        return data instanceof Response?data:response(data);
      } catch (e) {
        const known = e instanceof ApiError; const status = known ? e.status : 503;
        const code = known ? e.code : 'TEMPORARILY_UNAVAILABLE';
        return response(modern ? { ok: false, error: { code, message: code, retryable: status >= 500 || status === 429 }, request_id: requestId }
          : { ok: false, error: code, request_id: requestId }, status, known ? e.headers : {});
      }
    },
    async scheduled(controller, env, ctx) {
      if (!env.DB?.prepare) return;
      const db = env.DB.withSession ? env.DB.withSession('first-primary') : env.DB;
      const work = async () => { await drainBark(env, db, deps); await cleanup(db, deps.now()); await sweepRecovery(env,db,deps.now()); };
      // Persisted outbox/lease survives failed runs; never log request or error bodies.
      ctx.waitUntil(work().catch(() => console.error('nu_chat_maintenance_failed')));
    }
  };
}
export default createWorker();
