import type { Metadata } from 'next'
import { Shell } from '@/components/Chrome'
import { fragments } from '@/content/fragments'
import { esc, safeHref } from '@/lib/html'
import { mediaAlt, mediaUrl, payload } from '@/lib/payload'

export const dynamic = 'force-static'

const description = 'Brands, organisations and sponsors: work with Lumalook to get every skin seen properly, on camera and on screen.'
export const metadata: Metadata = {
  title: 'Partners',
  description,
  alternates: { canonical: '/partners' },
  openGraph: { title: 'Partner with Lumalook', description, url: '/partners' },
}

const OPEN = ['Founding partner', 'Founding partner', 'Community partner', 'Education partner']

export default async function PartnersPage() {
  const p = await payload()
  const { docs } = await p.find({ collection: 'our-partners', where: { published: { equals: true } }, sort: 'order', limit: 24, depth: 1 })
  const tiles = docs.map((d) => {
    const logo = mediaUrl(d.logo as never, 'card')
    const inner = logo
      ? `<img src="${esc(logo)}" alt="${esc(mediaAlt(d.logo as never) || d.name)}" loading="lazy">`
      : `<span><b>${esc(d.name)}</b>${esc(d.kind)}</span>`
    const href = safeHref(d.url)
    return href
      ? `<a class="slot filled" href="${esc(href)}" rel="noopener">${inner}</a>`
      : `<div class="slot filled">${inner}</div>`
  })
  for (let i = docs.length; i < 4; i++) tiles.push(`<div class="slot"><span><b>${OPEN[i]}</b>Space open</span></div>`)
  const slots = `      <div class="slots">\n${tiles.join('\n')}\n      </div>\n`
  return (
    <Shell cta={<a className="btn btn-y btn-sm" href="#enquire">Enquire</a>} scripts={['partners']} html={fragments.partnersBefore + slots + fragments.partnersAfter} />
  )
}
