import type { GetStaticProps } from 'next'
import { Shell } from '@/components/Chrome'
import { Meta } from '@/components/Meta'
import type { Post } from '@/payload-types'
import { formatDate, mediaAlt, mediaUrl } from '@/lib/media'
import { payload } from '@/lib/payload'

export const config = { runtime: 'nodejs', unstable_runtimeJS: false }

type Props = { feature: Post | null; rest: Post[] }

export const getStaticProps: GetStaticProps<Props> = async () => {
  const p = await payload()
  const { docs } = await p.find({ collection: 'posts', where: { _status: { equals: 'published' } }, sort: '-publishedAt', limit: 100, depth: 1 })
  const live = docs.filter((d) => !d.comingSoon)
  const feature = live.find((d) => d.featured) || live[0] || null
  const rest = docs.filter((d) => d !== feature)
  return { props: JSON.parse(JSON.stringify({ feature, rest })), revalidate: 600 }
}

const description = 'Notes on skin, light and film from the team behind Lumalook.'

export default function BlogPage({ feature, rest }: Props) {
  return (
    <>
      <Meta title="Blog · Lumalook" description={description} path="/blog" />
    <Shell active="blog">
        <section className="page-hero">
          <div className="wrap">
            <p className="kicker y">Blog</p>
            <h1 className="lh grad">
              <span className="l">Notes on skin,</span> <span className="h">light and film.</span>
            </h1>
            <p className="lede">What we’re learning as we build Lumalook: the science of colour, how to shoot deep skin well, and what our Founding Creators teach us.</p>
          </div>
        </section>
  
        <section className="sec tight" style={{ paddingTop: 8 }}>
          <div className="wrap">
            {feature ? (
              <a className="post-feature" href={`/blog/${feature.slug}`}>
                <div className="img">{mediaUrl(feature.cover as never) ? <img src={mediaUrl(feature.cover as never, 'wide')} alt={mediaAlt(feature.cover as never)} loading="lazy" /> : null}</div>
                <div className="txt">
                  <div className="post-meta">
                    <span className="cat">{feature.category}</span>
                    <span>{formatDate(feature.publishedAt)}</span>
                    {feature.readTime ? <span>{feature.readTime}</span> : null}
                  </div>
                  <h2>{feature.title}</h2>
                  <p>{feature.excerpt}</p>
                  <span className="btn btn-g" style={{ justifySelf: 'start', marginTop: 6 }}>Read the post</span>
                </div>
              </a>
            ) : null}
            {rest.length ? (
              <div className="post-grid">
                {rest.map((d) =>
                  d.comingSoon ? (
                    <div className="post-card soon" key={d.id}>
                      <div className="post-meta"><span className="cat">{d.category}</span><span className="draft">Coming soon</span></div>
                      <h3>{d.title}</h3>
                      <p>{d.excerpt}</p>
                    </div>
                  ) : (
                    <a className="post-card" key={d.id} href={`/blog/${d.slug}`}>
                      <div className="post-meta"><span className="cat">{d.category}</span><span>{formatDate(d.publishedAt)}</span></div>
                      <h3>{d.title}</h3>
                      <p>{d.excerpt}</p>
                    </a>
                  ),
                )}
              </div>
            ) : null}
          </div>
        </section>
  
        <section className="sec tight">
          <div className="wrap">
            <div className="band-cta">
              <div>
                <h2 className="lh grad"><span className="l">Hear when</span> <span className="h">we launch.</span></h2>
                <p>One email on launch day, nothing else. New posts will always be here first.</p>
              </div>
              <div className="cta"><a className="btn btn-y btn-lg" href="/#get">Join the waitlist</a></div>
            </div>
          </div>
        </section>
      </Shell>
    </>
  )
}
