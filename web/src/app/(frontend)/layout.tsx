import React from 'react'
import type { Metadata, Viewport } from 'next'

export const metadata: Metadata = {
  metadataBase: new URL('https://lumalook.app'),
  title: { default: 'Lumalook: film looks true to every skin', template: '%s · Lumalook' },
  openGraph: { siteName: 'Lumalook', type: 'website', images: ['/assets/img/og.jpg'] },
  twitter: { card: 'summary_large_image' },
  icons: { icon: { url: '/assets/img/favicon.svg', type: 'image/svg+xml' }, apple: '/assets/img/apple-touch-icon.png' },
}

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  viewportFit: 'cover',
  themeColor: '#08090a',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en-GB">
      <head>
        <link rel="preload" href="/assets/fonts/inter-latin.woff2" as="font" type="font/woff2" crossOrigin="" />
        <link rel="stylesheet" href="/assets/site.css" />
        <script dangerouslySetInnerHTML={{ __html: 'document.documentElement.classList.add("js")' }} />
      </head>
      <body>{children}</body>
    </html>
  )
}
