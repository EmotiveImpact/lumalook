import type { GetStaticProps } from 'next'
import { Shell } from '@/components/Chrome'
import { Meta } from '@/components/Meta'
import { fragments } from '@/content/fragments'
import { esc } from '@/lib/html'
import { mediaAlt, mediaUrl } from '@/lib/media'
import { payload } from '@/lib/payload'

export const config = { runtime: 'nodejs', unstable_runtimeJS: false }

type Props = { html: string }

export const getStaticProps: GetStaticProps<Props> = async () => {
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
  return { props: { html: fragments.missionBefore + founder + fragments.missionAfter }, revalidate: 600 }
}

export default function MissionPage({ html }: Props) {
  return (
    <>
      <Meta
        title="Our mission · Lumalook"
        description="Why Lumalook exists: film looks true to every skin, from the history of the Shirley card to how we test every look on deep skin."
        ogTitle="Lumalook: film looks true to every skin"
        path="/mission"
      />
      <Shell active="mission" html={html} />
    </>
  )
}
