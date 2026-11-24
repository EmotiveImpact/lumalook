import type { Metadata } from 'next'
import { Shell } from '@/components/Chrome'
import { fragments } from '@/content/fragments'
import { esc } from '@/lib/html'
import { mediaAlt, mediaUrl, payload } from '@/lib/payload'

export const dynamic = 'force-static'

const description = 'Why Lumalook exists: film looks true to every skin, from the history of the Shirley card to how we test every look on deep skin.'
export const metadata: Metadata = {
  title: 'Our mission',
  description,
  alternates: { canonical: '/mission' },
  openGraph: { title: 'Lumalook: film looks true to every skin', description, url: '/mission' },
}

export default async function MissionPage() {
  const p = await payload()
  const m = await p.findGlobal({ slug: 'mission', depth: 1 })
  let founder: string
  if (m.founderNote?.trim()) {
    const paras = m.founderNote.trim().split(/\n\s*\n/).map((t) => `<p>${esc(t).replace(/\n/g, '<br>')}</p>`).join('\n')
    const photo = mediaUrl(m.founderPhoto as never, 'card')
    founder =
      `<div class="founder-note">${photo ? `<img src="${esc(photo)}" alt="${esc(mediaAlt(m.founderPhoto as never))}" loading="lazy">` : ''}` +
      `<div>${paras}${m.founderName ? `<p class="founder-name">${esc(m.founderName)}</p>` : ''}</div></div>\n`
  } else {
    founder = `        <p><em class="placeholder">[Founder note: a few lines from Edem on why you started Lumalook, in your own words. We'll put your name and photo here once you've written it.]</em></p>\n`
  }
  return (
    <Shell active="mission" html={fragments.missionBefore + founder + fragments.missionAfter} />
  )
}
