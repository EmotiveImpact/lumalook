import { createHash, timingSafeEqual } from 'crypto'
import type { NextApiRequest, NextApiResponse } from 'next'

// Called by Payload after an edit: rebuilds just the pages that show it.
export function revalidateToken() {
  return createHash('sha256').update(`revalidate:${process.env.PAYLOAD_SECRET || ''}`).digest('hex')
}

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== 'POST') return res.status(405).end()
  const given = Buffer.from(String(req.headers['x-revalidate-token'] || ''))
  const want = Buffer.from(revalidateToken())
  if (!process.env.PAYLOAD_SECRET || given.length !== want.length || !timingSafeEqual(given, want)) return res.status(401).end()
  const paths: unknown = req.body?.paths
  if (!Array.isArray(paths)) return res.status(400).end()
  const done: string[] = []
  for (const p of paths) {
    if (typeof p !== 'string' || !p.startsWith('/')) continue
    try {
      await res.revalidate(p)
      done.push(p)
    } catch {
      /* page not built yet or removed: fine */
    }
  }
  return res.json({ revalidated: done })
}
