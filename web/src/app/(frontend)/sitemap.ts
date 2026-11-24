import type { MetadataRoute } from 'next'
import { payload } from '@/lib/payload'

export const revalidate = 600

const BASE = 'https://lumalook.app'
const FIXED = ['', '/mission', '/showcase', '/blog', '/partners', '/founders', '/support', '/privacy', '/terms']

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const p = await payload()
  const { docs } = await p.find({ collection: 'posts', where: { _status: { equals: 'published' } }, limit: 500, depth: 0, select: { slug: true, comingSoon: true, updatedAt: true } })
  return [
    ...FIXED.map((path) => ({ url: BASE + path })),
    ...docs.filter((d) => !d.comingSoon).map((d) => ({ url: `${BASE}/blog/${d.slug}`, lastModified: d.updatedAt })),
  ]
}
