const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

export default {
  async fetch(request, env) {
    if (new URL(request.url).pathname !== '/v1/check-in') return new Response(null, { status: 404 })
    if (request.method !== 'POST') return new Response(null, { status: 405 })
    if (request.headers.get('content-length') !== '36') return new Response(null, { status: 400 })
    const limit = await env.LIMITER.limit({ key: request.headers.get('CF-Connecting-IP') || 'unknown' })
    if (!limit.success) return new Response(null, { status: 429 })
    const id = await request.text()
    if (!uuid.test(id)) return new Response(null, { status: 400 })
    await env.DB.prepare(`INSERT INTO installations (id, last_seen) VALUES (?, date('now'))
      ON CONFLICT(id) DO UPDATE SET last_seen = excluded.last_seen
      WHERE last_seen < excluded.last_seen`).bind(id).run()
    return new Response(null, { status: 204 })
  },
  async scheduled(event, env) {
    await env.DB.prepare("DELETE FROM installations WHERE last_seen < date('now', '-29 days')").run()
  },
}
