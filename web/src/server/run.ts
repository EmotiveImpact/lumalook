// Runs one of the original (req, res) form handlers inside a Next.js route.
type Handler = (req: { method: string; body: unknown }, res: Res) => unknown
type Res = {
  setHeader(k: string, v: string): void
  status(code: number): Res
  json(body: unknown): void
}

export async function run(handler: Handler, request: Request): Promise<Response> {
  const headers = new Headers()
  let code = 200
  let payload: unknown = null
  const res: Res = {
    setHeader: (k, v) => headers.set(k, v),
    status(c) {
      code = c
      return res
    },
    json(body) {
      payload = body
    },
  }
  // Parse the body the way Vercel's Node functions did: JSON and form posts
  // arrive as objects, anything else as a string.
  let body: unknown = ''
  if (request.method === 'POST') {
    const text = await request.text()
    const type = request.headers.get('content-type') || ''
    if (type.includes('application/json')) {
      try {
        body = JSON.parse(text)
      } catch {
        body = text
      }
    } else if (type.includes('application/x-www-form-urlencoded')) {
      const params = new URLSearchParams(text)
      const obj: Record<string, string | string[]> = {}
      for (const [k, v] of params) {
        const prev = obj[k]
        obj[k] = prev === undefined ? v : Array.isArray(prev) ? [...prev, v] : [prev, v]
      }
      body = obj
    } else {
      body = text
    }
  }
  await handler({ method: request.method, body }, res)
  return Response.json(payload, { status: code, headers })
}
