import { Head, Html, Main, NextScript } from 'next/document'

export default function Document() {
  return (
    <Html lang="en-GB">
      <Head>
        <meta name="theme-color" content="#08090a" />
        <link rel="icon" href="/assets/img/favicon.svg" type="image/svg+xml" />
        <link rel="apple-touch-icon" href="/assets/img/apple-touch-icon.png" />
        <link rel="preload" href="/assets/fonts/inter-latin.woff2" as="font" type="font/woff2" crossOrigin="" />
        <link rel="stylesheet" href="/assets/site.css" />
        <script dangerouslySetInnerHTML={{ __html: 'document.documentElement.classList.add("js")' }} />
      </Head>
      <body>
        <Main />
        <NextScript />
      </body>
    </Html>
  )
}
