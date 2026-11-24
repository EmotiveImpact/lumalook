// Escape text from the CMS before it goes into a page's markup.
export function esc(s: unknown): string {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string)
}

// Only allow ordinary web or site-relative links from the CMS.
export function safeHref(u: unknown): string | null {
  const s = String(u ?? '').trim()
  if (/^https?:\/\//i.test(s) || s.startsWith('/')) return s
  if (/^[a-z0-9.-]+\.[a-z]{2,}(\/.*)?$/i.test(s)) return 'https://' + s
  return null
}
