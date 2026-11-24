import type { Metadata } from 'next'
import { Footer, Nav, PageScripts } from '@/components/Chrome'
import { pages } from '@/content/staticPages'

// Unknown addresses anywhere on the site get the same 404 page as the old site.
export const metadata: Metadata = { title: pages.notfound.title, robots: { index: false } }

export default function GlobalNotFound() {
  const p = pages.notfound
  return (
    <html lang="en-GB">
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
        <meta name="theme-color" content="#08090a" />
        <link rel="icon" href="/assets/img/favicon.svg" type="image/svg+xml" />
        <link rel="stylesheet" href="/assets/site.css" />
        <script dangerouslySetInnerHTML={{ __html: 'document.documentElement.classList.add("js")' }} />
      </head>
      <body>
        <a className="skip" href="#main">Skip to content</a>
        <Nav cta={<span style={{ display: 'contents' }} dangerouslySetInnerHTML={{ __html: p.cta }} />} />
        <main id="main" dangerouslySetInnerHTML={{ __html: p.html }} />
        <Footer />
        <PageScripts names={p.scripts} />
      </body>
    </html>
  )
}
