// Pure helpers, safe to import anywhere (no Payload or database code).

export type MediaLike = { url?: string | null; alt?: string | null; sizes?: Record<string, { url?: string | null } | undefined> } | number | null | undefined

export function mediaUrl(m: MediaLike, size?: 'card' | 'wide'): string | undefined {
  if (!m || typeof m === 'number') return undefined
  const url = (size && m.sizes?.[size]?.url) || m.url || undefined
  // Local uploads come back absolute (serverURL + /api/media/...). Keep them relative so
  // they work on every host; Blob storage URLs stay absolute.
  return url?.replace(/^https?:\/\/[^/]+(?=\/api\/media\/)/, '')
}

export function mediaAlt(m: MediaLike): string {
  return m && typeof m !== 'number' ? m.alt || '' : ''
}

export function formatDate(d?: string | null): string {
  if (!d) return ''
  return new Date(d).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'Europe/London' })
}
