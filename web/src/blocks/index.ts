import type { Block } from 'payload'

// Blocks an author can drop into a blog post, matching the site's own styles.
export const StatRow: Block = {
  slug: 'statRow',
  labels: { singular: 'Stat row', plural: 'Stat rows' },
  fields: [
    {
      name: 'stats',
      type: 'array',
      minRows: 1,
      maxRows: 3,
      fields: [
        { name: 'value', type: 'text', required: true, admin: { description: 'Big figure, e.g. "123 of 128"' } },
        { name: 'label', type: 'text', required: true },
      ],
    },
  ],
}

export const ToneStrip: Block = {
  slug: 'toneStrip',
  labels: { singular: 'Monk tone strip', plural: 'Monk tone strips' },
  fields: [
    { name: 'caption', type: 'text', defaultValue: 'The Monk Skin Tone Scale by Ellis Monk, 1 to 10.' },
  ],
}

export const Button: Block = {
  slug: 'button',
  labels: { singular: 'Button', plural: 'Buttons' },
  fields: [
    { name: 'label', type: 'text', required: true },
    { name: 'href', type: 'text', required: true, admin: { description: 'e.g. /founders' } },
  ],
}

export const postBlocks = [StatRow, ToneStrip, Button]
