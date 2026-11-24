import React from 'react'
import { RichText, type JSXConvertersFunction } from '@payloadcms/richtext-lexical/react'
import type { SerializedEditorState } from '@payloadcms/richtext-lexical/lexical'

const TONES = ['#f6ede4', '#f3e7db', '#f7ead0', '#eadaba', '#d7bd96', '#a07e56', '#825c43', '#604134', '#3a312a', '#292420']

type StatRowFields = { stats?: { value: string; label: string }[] }
type ToneFields = { caption?: string }
type ButtonFields = { label: string; href: string }
type BlockArgs = { node: { fields: unknown } }

const converters: JSXConvertersFunction = ({ defaultConverters }) => ({
  ...defaultConverters,
  blocks: {
    statRow: ({ node }: BlockArgs) => {
      const f = node.fields as unknown as StatRowFields
      return (
        <div className="stat-row">
          {(f.stats || []).map((s, i) => (
            <div key={i}>
              <b>{s.value}</b>
              <span>{s.label}</span>
            </div>
          ))}
        </div>
      )
    },
    toneStrip: ({ node }: BlockArgs) => {
      const f = node.fields as unknown as ToneFields
      return (
        <>
          <div className="tone-strip" aria-hidden="true">
            {TONES.map((c) => (
              <i key={c} style={{ ['--c' as string]: c }} />
            ))}
          </div>
          {f.caption ? <p className="tone-cap">{f.caption}</p> : null}
        </>
      )
    },
    button: ({ node }: BlockArgs) => {
      const f = node.fields as unknown as ButtonFields
      return (
        <p>
          <a className="btn btn-y" href={f.href} style={{ textDecoration: 'none', color: 'var(--on-signal)' }}>
            {f.label}
          </a>
        </p>
      )
    },
  },
})

export function PostBody({ data }: { data: SerializedEditorState }) {
  return <RichText data={data} converters={converters} disableContainer />
}
