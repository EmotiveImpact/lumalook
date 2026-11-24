import type { CollectionConfig } from 'payload'

export const Media: CollectionConfig = {
  slug: 'media',
  access: { read: () => true },
  admin: { description: 'Images used on the site. Always write alt text: it describes the picture for screen readers and search engines.' },
  fields: [{ name: 'alt', type: 'text', required: true }],
  upload: {
    mimeTypes: ['image/*'],
    imageSizes: [
      { name: 'card', width: 900 },
      { name: 'wide', width: 1800 },
    ],
    formatOptions: { format: 'webp', options: { quality: 82 } },
  },
}
