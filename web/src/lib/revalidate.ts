import { createHash } from 'crypto'

// Pages are built ahead of time. When something changes in the admin, ask the
// site to rebuild only the pages that show it. Pages also refresh on their own
// every ten minutes, so a missed call is never permanent.
function origin(): string | undefined {
  if (process.env.NEXT_PUBLIC_SERVER_URL) return process.env.NEXT_PUBLIC_SERVER_URL
  if (process.env.VERCEL_URL) return `https://${process.env.VERCEL_URL}`
  return undefined
}

export async function revalidate(paths: string[]) {
  const base = origin()
  if (!base || !process.env.PAYLOAD_SECRET) return
  const token = createHash('sha256').update(`revalidate:${process.env.PAYLOAD_SECRET}`).digest('hex')
  const headers: Record<string, string> = { 'content-type': 'application/json', 'x-revalidate-token': token }
  // Lets the call through Vercel's preview protection when that is switched on.
  if (process.env.VERCEL_AUTOMATION_BYPASS_SECRET) headers['x-vercel-protection-bypass'] = process.env.VERCEL_AUTOMATION_BYPASS_SECRET
  try {
    await fetch(`${base}/api/revalidate`, { method: 'POST', headers, body: JSON.stringify({ paths }), signal: AbortSignal.timeout(8000) })
  } catch {
    /* site not reachable (seed script, build): pages refresh on their own */
  }
}

