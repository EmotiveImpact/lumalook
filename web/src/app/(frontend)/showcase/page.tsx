import type { Metadata } from 'next'
import { Shell } from '@/components/Chrome'
import { fragments } from '@/content/fragments'
import { esc, safeHref } from '@/lib/html'
import { mediaAlt, mediaUrl, payload } from '@/lib/payload'

export const dynamic = 'force-static'

const description = 'Photos and films made with Lumalook, shared with permission and credited to the creators who made them.'
export const metadata: Metadata = {
  title: 'Showcase',
  description,
  alternates: { canonical: '/showcase' },
  openGraph: { title: 'Made with Lumalook', description, url: '/showcase' },
}

const EMPTY = '<div class="show-tile empty"><div><i>+</i><b>Your work here</b><small>Shot or graded with Lumalook</small></div></div>'
const EMPTY_WIDE = EMPTY.replace('show-tile empty', 'show-tile empty wide')

export default async function ShowcasePage() {
  const p = await payload()
  const { docs } = await p.find({ collection: 'showcase', where: { published: { equals: true } }, sort: 'order', limit: 60, depth: 1 })
  const tiles = docs.map((d) => {
    const shape = d.shape && d.shape !== 'normal' ? ` ${d.shape}` : ''
    const img = mediaUrl(d.image as never, d.shape === 'wide' ? 'wide' : 'card')
    const who = [d.handle, d.city].filter(Boolean).map(esc).join(' · ')
    const fig =
      `<figure class="show-tile${shape}">${d.isExample ? '<span class="flag">Example layout</span>' : ''}` +
      `<img src="${esc(img)}" alt="${esc(mediaAlt(d.image as never))}" loading="lazy">` +
      `<figcaption><span><b>${esc(d.creatorName)}</b>${who ? `<small>${who}</small>` : ''}</span>${d.look ? `<span class="look">${esc(d.look)}</span>` : ''}</figcaption></figure>`
    const href = safeHref(d.link)
    return href ? `<a href="${esc(href)}" rel="noopener" style="display:contents">${fig}</a>` : fig
  })
  // Keep the grid looking intentional while it fills: pad to seven tiles.
  // Template: [tall, n, n, wide, n, n, n]; real work fills slots 0, 4, 1, 2, 5, 6, 3 in turn.
  if (tiles.length < 7) {
    const slots: string[] = [EMPTY, EMPTY, EMPTY, EMPTY_WIDE, EMPTY, EMPTY, EMPTY]
    const order = [0, 4, 1, 2, 5, 6, 3]
    tiles.forEach((t, i) => (slots[order[i]] = t))
    tiles.splice(0, tiles.length, ...slots)
  }
  const real = docs.filter((d) => !d.isExample).length
  const note = docs.some((d) => d.isExample)
    ? '      <p class="feat-note" style="margin-top:16px">The example tiles use the app&#39;s own sample photos to show how work will be credited. The first real spots go to our Founding Creators.</p>\n'
    : real === 0
      ? '      <p class="feat-note" style="margin-top:16px">The first spots go to our Founding Creators.</p>\n'
      : ''
  const grid = `      <div class="show-grid">\n${tiles.join('\n')}\n      </div>\n${note}`
  return (
    <Shell active="showcase" html={fragments.showcaseBefore + grid + fragments.showcaseAfter} />
  )
}
