import type { CollectionConfig } from 'payload'
import { revalidate } from '../lib/revalidate'

export const Showcase: CollectionConfig = {
  slug: 'showcase',
  labels: { singular: 'Showcase piece', plural: 'Showcase' },
  admin: {
    useAsTitle: 'creatorName',
    defaultColumns: ['creatorName', 'handle', 'look', 'published', 'order'],
    description: 'Work shown on lumalook.app/showcase. Only add work the creator has agreed to share.',
  },
  access: {
    read: ({ req }) => (req.user ? true : { published: { equals: true } }),
  },
  defaultSort: 'order',
  fields: [
    {
      type: 'row',
      fields: [
        { name: 'creatorName', type: 'text', required: true },
        { name: 'handle', type: 'text', admin: { description: 'e.g. @name' } },
        { name: 'city', type: 'text' },
      ],
    },
    { name: 'image', type: 'upload', relationTo: 'media', required: true },
    {
      type: 'row',
      fields: [
        { name: 'look', type: 'text', admin: { description: 'The Lumalook look used' } },
        {
          name: 'category',
          type: 'select',
          options: ['Portrait', 'Night', 'Music', 'Fashion and beauty', 'Weddings', 'Video'],
        },
        {
          name: 'shape',
          type: 'select',
          defaultValue: 'normal',
          options: [
            { label: 'Normal', value: 'normal' },
            { label: 'Tall', value: 'tall' },
            { label: 'Wide', value: 'wide' },
          ],
        },
      ],
    },
    { name: 'link', type: 'text', admin: { description: 'Optional link to the post or the creator' } },
    { name: 'permission', type: 'checkbox', required: true, label: 'The creator has agreed to us showing this, with credit', validate: (v: boolean | null | undefined) => (v ? true : 'Get the creator’s permission first') },
    { name: 'isExample', type: 'checkbox', defaultValue: false, label: 'Example layout (our own sample photo, not a creator’s work)', admin: { position: 'sidebar' } },
    { name: 'published', type: 'checkbox', defaultValue: true, admin: { position: 'sidebar' } },
    { name: 'order', type: 'number', defaultValue: 100, admin: { position: 'sidebar', description: 'Lower shows first' } },
  ],
  hooks: {
    afterChange: [() => revalidate(['/showcase'])],
    afterDelete: [() => revalidate(['/showcase'])],
  },
}
