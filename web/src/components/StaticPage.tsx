import type { Metadata } from 'next'
import { pages } from '@/content/staticPages'
import { Footer, Nav, PageScripts } from './Chrome'

export function staticMetadata(key: string, path: string): Metadata {
  const p = pages[key]
  return {
    title: { absolute: p.title },
    description: p.description ?? undefined,
    alternates: { canonical: path },
    robots: p.noindex ? { index: false } : undefined,
    openGraph: {
      title: p.ogTitle ?? p.title,
      description: p.ogDescription ?? p.description ?? undefined,
      url: path,
    },
  }
}

// Fixed pages carried over from the original site, rendered from their
// original markup so they look exactly the same.
export function StaticPage({ name, active }: { name: string; active?: 'mission' | 'showcase' | 'blog' }) {
  const p = pages[name]
  return (
    <>
      <a className="skip" href="#main">Skip to content</a>
      <Nav active={active} cta={<span style={{ display: 'contents' }} dangerouslySetInnerHTML={{ __html: p.cta }} />} />
      <main id="main" dangerouslySetInnerHTML={{ __html: p.html }} />
      <Footer />
      <PageScripts names={p.scripts} />
    </>
  )
}
