import { withPayload } from '@payloadcms/next/withPayload'
import type { NextConfig } from 'next'
import path from 'path'
import { fileURLToPath } from 'url'

const __filename = fileURLToPath(import.meta.url)
const dirname = path.dirname(__filename)

const security = [
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
]

const nextConfig: NextConfig = {
  poweredByHeader: false,
  experimental: { globalNotFound: true },
  async headers() {
    return [
      { source: '/:path*', headers: security },
      { source: '/assets/:file(.*\\.(?:css|js))', headers: [{ key: 'Cache-Control', value: 'public, max-age=0, must-revalidate' }] },
      { source: '/assets/:dir(fonts|img)/:path*', headers: [{ key: 'Cache-Control', value: 'public, max-age=86400, stale-while-revalidate=604800' }] },
    ]
  },
  async redirects() {
    return [
      // Old addresses from the static site
      { source: '/index.html', destination: '/', permanent: true },
      { source: '/:page(privacy|terms|support|founders|thanks|mission|partners|showcase|blog|404).html', destination: '/:page', permanent: true },
      { source: '/blog/:slug.html', destination: '/blog/:slug', permanent: true },
      // lumalook.vercel.app is an alias of the live site
      { source: '/:path*', has: [{ type: 'host', value: 'lumalook.vercel.app' }], destination: 'https://lumalook.app/:path*', permanent: true },
    ]
  },
  images: {
    localPatterns: [
      {
        pathname: '/api/media/file/**',
      },
    ],
  },
  webpack: (webpackConfig) => {
    webpackConfig.resolve.extensionAlias = {
      '.cjs': ['.cts', '.cjs'],
      '.js': ['.ts', '.tsx', '.js', '.jsx'],
      '.mjs': ['.mts', '.mjs'],
    }

    return webpackConfig
  },
  turbopack: {
    root: path.resolve(dirname),
  },
}

export default withPayload(nextConfig, { devBundleServerPackages: false })
