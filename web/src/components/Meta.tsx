import Head from 'next/head'

const SITE = 'https://lumalook.app'

export type PageMeta = {
  title: string // full title, as it appears in the tab
  description?: string | null
  path: string
  noindex?: boolean
  ogTitle?: string | null
  ogDescription?: string | null
  ogType?: 'website' | 'article'
  image?: string | null
  publishedTime?: string | null
}

const abs = (u: string) => new URL(u, SITE).toString()

export function Meta(m: PageMeta) {
  const image = abs(m.image || '/assets/img/og.jpg')
  const ogTitle = m.ogTitle || m.title
  const ogDescription = m.ogDescription || m.description || undefined
  return (
    <Head>
      <title>{m.title}</title>
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" key="viewport" />
      {m.description ? <meta name="description" content={m.description} /> : null}
      {m.noindex ? <meta name="robots" content="noindex" /> : null}
      <link rel="canonical" href={abs(m.path)} />
      <meta property="og:site_name" content="Lumalook" />
      <meta property="og:type" content={m.ogType || 'website'} />
      <meta property="og:title" content={ogTitle} />
      {ogDescription ? <meta property="og:description" content={ogDescription} /> : null}
      <meta property="og:url" content={abs(m.path)} />
      <meta property="og:image" content={image} />
      {m.publishedTime ? <meta property="article:published_time" content={m.publishedTime} /> : null}
      <meta name="twitter:card" content="summary_large_image" />
      <meta name="twitter:title" content={ogTitle} />
      {ogDescription ? <meta name="twitter:description" content={ogDescription} /> : null}
      <meta name="twitter:image" content={image} />
    </Head>
  )
}

export const titled = (t: string) => `${t} · Lumalook`
