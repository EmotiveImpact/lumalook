import { pages } from '@/content/staticPages'
import { Footer, Nav, PageScripts } from './Chrome'
import { Meta } from './Meta'

// Fixed pages carried over from the original site, rendered from their
// original markup so they look exactly the same.
export function StaticPage({ name, path, active }: { name: string; path: string; active?: 'mission' | 'showcase' | 'blog' }) {
  const p = pages[name]
  return (
    <>
      <Meta title={p.title} description={p.description} path={path} noindex={p.noindex} ogTitle={p.ogTitle} ogDescription={p.ogDescription} />
      <a className="skip" href="#main">Skip to content</a>
      <Nav active={active} cta={<span style={{ display: 'contents' }} dangerouslySetInnerHTML={{ __html: p.cta }} />} />
      <main id="main" dangerouslySetInnerHTML={{ __html: p.html }} />
      <Footer />
      <PageScripts names={p.scripts} />
    </>
  )
}
