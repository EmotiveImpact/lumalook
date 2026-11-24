import type { GlobalConfig } from 'payload'
import { revalidate } from '../lib/revalidate'

export const Mission: GlobalConfig = {
  slug: 'mission',
  label: 'Mission page',
  access: { read: () => true },
  fields: [
    {
      name: 'founderNote',
      type: 'textarea',
      admin: { description: 'A few lines in your own words on why you started Lumalook. Leave empty to show the placeholder.' },
    },
    {
      type: 'row',
      fields: [
        { name: 'founderName', type: 'text', admin: { description: 'e.g. Edem, founder' } },
        { name: 'founderPhoto', type: 'upload', relationTo: 'media' },
      ],
    },
  ],
  hooks: { afterChange: [() => revalidate(['/mission'])] },
}
