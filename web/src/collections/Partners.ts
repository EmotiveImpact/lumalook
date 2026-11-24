import type { CollectionConfig } from 'payload'
import { revalidate } from '../lib/revalidate'

export const Partners: CollectionConfig = {
  slug: 'our-partners',
  labels: { singular: 'Partner', plural: 'Partners' },
  admin: {
    useAsTitle: 'name',
    defaultColumns: ['name', 'kind', 'published', 'order'],
    description: 'Shown under "Our partners" on lumalook.app/partners. Only list partners who have agreed to be named. Empty spaces fill the row until there are four.',
  },
  access: {
    read: ({ req }) => (req.user ? true : { published: { equals: true } }),
  },
  defaultSort: 'order',
  fields: [
    { name: 'name', type: 'text', required: true },
    {
      name: 'kind',
      type: 'select',
      required: true,
      defaultValue: 'Founding partner',
      options: ['Founding partner', 'Community partner', 'Education partner', 'Brand partner', 'Sponsor'],
    },
    { name: 'logo', type: 'upload', relationTo: 'media', admin: { description: 'Light logo on a transparent background works best' } },
    { name: 'url', type: 'text' },
    { name: 'published', type: 'checkbox', defaultValue: true, admin: { position: 'sidebar' } },
    { name: 'order', type: 'number', defaultValue: 100, admin: { position: 'sidebar' } },
  ],
  hooks: {
    afterChange: [() => revalidate(['/partners'])],
    afterDelete: [() => revalidate(['/partners'])],
  },
}
