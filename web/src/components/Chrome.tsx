import React from 'react'

type Active = 'mission' | 'showcase' | 'blog' | undefined

const links: { href: string; label: string; key?: Active }[] = [
  { href: '/mission', label: 'Mission', key: 'mission' },
  { href: '/#how', label: 'How it works' },
  { href: '/#looks', label: 'Looks' },
  { href: '/#pricing', label: 'Pricing' },
  { href: '/showcase', label: 'Showcase', key: 'showcase' },
  { href: '/blog', label: 'Blog', key: 'blog' },
]

// Plain <a> links on purpose: every page is a full load, so the small page
// scripts (store button, waitlist, forms) run on each page as they always have.
export function Nav({ active, cta }: { active?: Active; cta?: React.ReactNode }) {
  return (
    <header className="nav" id="nav">
      <div className="wrap">
        <a className="mark" href="/" aria-label="Lumalook home">
          <i></i>lumalook
        </a>
        <nav className="nav-links" aria-label="Main">
          {links.map((l) => (
            <a key={l.href} href={l.href} aria-current={l.key && l.key === active ? 'page' : undefined}>
              {l.label}
            </a>
          ))}
        </nav>
        <div className="nav-cta">
          {cta ?? (
            <a className="btn btn-y btn-sm" href="/#get" data-store="">
              Get the app
            </a>
          )}
        </div>
      </div>
    </header>
  )
}

export function Footer() {
  return (
    <footer className="foot">
      <div className="wrap">
        <div className="foot-grid five">
          <div>
            <a className="mark" href="/">
              <i></i>lumalook
            </a>
            <p className="tag">Film looks true to every skin. Shoot, grade and edit on iPhone.</p>
          </div>
          <div>
            <h4>App</h4>
            <ul>
              <li><a href="/#how">How it works</a></li>
              <li><a href="/#looks">Looks and packs</a></li>
              <li><a href="/#pricing">Pricing</a></li>
              <li><a href="/showcase">Showcase</a></li>
            </ul>
          </div>
          <div>
            <h4>Company</h4>
            <ul>
              <li><a href="/mission">Mission</a></li>
              <li><a href="/blog">Blog</a></li>
              <li><a href="/partners">Partners</a></li>
              <li><a href="/founders">Founding Creators</a></li>
            </ul>
          </div>
          <div>
            <h4>Help</h4>
            <ul>
              <li><a href="/support">Support</a></li>
              <li><a href="/support#restore">Restore purchases</a></li>
              <li><a href="/#faq">Questions</a></li>
            </ul>
          </div>
          <div>
            <h4>Legal</h4>
            <ul>
              <li><a href="/privacy">Privacy</a></li>
              <li><a href="/terms">Terms</a></li>
            </ul>
          </div>
        </div>
        <div className="foot-base">
          <p>
            &copy; 2026 Emotive Impact. Monk Skin Tone Scale by Ellis Monk, used under{' '}
            <a href="https://creativecommons.org/licenses/by/4.0/" rel="noopener">CC BY 4.0</a>.
          </p>
          <p>Apple, iPhone, TestFlight and App Store are trademarks of Apple Inc.</p>
        </div>
      </div>
    </footer>
  )
}

export function PageScripts({ names = [] }: { names?: string[] }) {
  return (
    <>
      <script src="/assets/site.js" defer></script>
      {names.map((n) => (
        <script key={n} src={`/assets/${n}.js`} defer></script>
      ))}
    </>
  )
}

export function Shell({
  active,
  cta,
  scripts,
  html,
  children,
}: {
  active?: Active
  cta?: React.ReactNode
  scripts?: string[]
  html?: string
  children?: React.ReactNode
}) {
  return (
    <>
      <a className="skip" href="#main">Skip to content</a>
      <Nav active={active} cta={cta} />
      {html !== undefined ? <main id="main" dangerouslySetInnerHTML={{ __html: html }} /> : <main id="main">{children}</main>}
      <Footer />
      <PageScripts names={scripts} />
    </>
  )
}
