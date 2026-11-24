import type { CollectionConfig } from 'payload'
import { BlocksFeature, lexicalEditor } from '@payloadcms/richtext-lexical'
import { postBlocks } from '../blocks'
import { revalidate } from '../lib/revalidate'

export const Posts: CollectionConfig = {
  slug: 'posts',
  labels: { singular: 'Blog post', plural: 'Blog posts' },
  admin: {
    useAsTitle: 'title',
    defaultColumns: ['title', 'category', 'publishedAt', 'comingSoon', '_status'],
    description: 'Blog posts. Save as a draft while writing; Publish puts it live. Tick "Coming soon" to list a post on the blog page before it is written.',
  },
  versions: { drafts: true },
  access: {
    read: ({ req }) => (req.user ? true : { _status: { equals: 'published' } }),
  },
  defaultSort: '-publishedAt',
  fields: [
    { name: 'title', type: 'text', required: true, admin: { description: 'Full title, used in search results and the blog list.' } },
    {
      type: 'row',
      fields: [
        { name: 'headlineLight', type: 'text', admin: { description: 'Headline, light part (e.g. "Why filters turn")' } },
        { name: 'headlineHeavy', type: 'text', admin: { description: 'Headline, bold part (e.g. "deep skin grey.")' } },
      ],
    },
    { name: 'slug', type: 'text', required: true, unique: true, index: true, admin: { position: 'sidebar', description: 'Web address: lumalook.app/blog/<slug>' } },
    { name: 'category', type: 'text', required: true, defaultValue: 'Colour science', admin: { position: 'sidebar' } },
    { name: 'publishedAt', type: 'date', admin: { position: 'sidebar', date: { pickerAppearance: 'dayOnly', displayFormat: 'd MMMM yyyy' } } },
    { name: 'readTime', type: 'text', defaultValue: '5 min read', admin: { position: 'sidebar' } },
    { name: 'comingSoon', type: 'checkbox', defaultValue: false, admin: { position: 'sidebar', description: 'Show on the blog page as "Coming soon", without a link.' } },
    { name: 'featured', type: 'checkbox', defaultValue: false, admin: { position: 'sidebar', description: 'Show as the big card at the top of the blog page.' } },
    { name: 'excerpt', type: 'textarea', required: true, admin: { description: 'One or two sentences for the blog list and search results.' } },
    { name: 'lede', type: 'textarea', admin: { description: 'Opening paragraph under the headline.' } },
    {
      type: 'row',
      fields: [
        { name: 'cover', type: 'upload', relationTo: 'media' },
        { name: 'coverCaption', type: 'text' },
      ],
    },
    {
      name: 'body',
      type: 'richText',
      editor: lexicalEditor({
        features: ({ defaultFeatures }) => [...defaultFeatures, BlocksFeature({ blocks: postBlocks })],
      }),
    },
    {
      name: 'credits',
      type: 'textarea',
      admin: { description: 'Small print under the post, for sources and licences.' },
    },
  ],
  hooks: {
    afterChange: [({ doc }) => revalidate(['/blog', `/blog/${doc.slug}`, '/sitemap.xml'])],
    afterDelete: [({ doc }) => revalidate(['/blog', `/blog/${doc.slug}`, '/sitemap.xml'])],
  },
}
