import { postgresAdapter } from '@payloadcms/db-postgres'
import { lexicalEditor } from '@payloadcms/richtext-lexical'
import { vercelBlobStorage } from '@payloadcms/storage-vercel-blob'
import path from 'path'
import { buildConfig } from 'payload'
import { fileURLToPath } from 'url'
import sharp from 'sharp'

import { Users } from './collections/Users'
import { Media } from './collections/Media'
import { Posts } from './collections/Posts'
import { Showcase } from './collections/Showcase'
import { Partners } from './collections/Partners'
import { Mission } from './globals/Mission'
import { migrations } from './migrations'

const filename = fileURLToPath(import.meta.url)
const dirname = path.dirname(filename)

export default buildConfig({
  serverURL: process.env.NEXT_PUBLIC_SERVER_URL || '',
  admin: {
    user: Users.slug,
    importMap: { baseDir: path.resolve(dirname) },
    meta: { titleSuffix: ' · Lumalook admin' },
  },
  collections: [Posts, Showcase, Partners, Media, Users],
  globals: [Mission],
  editor: lexicalEditor(),
  secret: process.env.PAYLOAD_SECRET || '',
  typescript: { outputFile: path.resolve(dirname, 'payload-types.ts') },
  db: postgresAdapter({
    pool: { connectionString: process.env.DATABASE_URL || '' },
    // Schema changes ship as migrations (src/migrations), run before each build.
    push: false,
    // No transactions: each save is written straight away, so the page rebuild that a
    // save triggers (src/lib/revalidate.ts) reads the new content, not the old.
    transactionOptions: false,
    prodMigrations: migrations,
  }),
  sharp,
  plugins: [
    // Uploads go to Vercel Blob when a token is set (production); otherwise to /media on disk.
    vercelBlobStorage({
      enabled: Boolean(process.env.BLOB_READ_WRITE_TOKEN),
      // Same database columns with or without Blob, so one set of migrations works everywhere.
      alwaysInsertFields: true,
      // Images load straight from the Blob CDN instead of through a server function.
      collections: { media: { disablePayloadAccessControl: true } },
      token: process.env.BLOB_READ_WRITE_TOKEN,
    }),
  ],
})
