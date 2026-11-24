// Tiny builders for Lexical rich text, so seed content can be written as code.
import { randomUUID } from 'crypto'

type Node = Record<string, unknown>
const base = { format: '', indent: 0, version: 1, direction: 'ltr' as const }

// Inline text: "**bold**" and "[label](/url)" are recognised.
export function inline(src: string): Node[] {
  const out: Node[] = []
  const re = /\*\*(.+?)\*\*|\[(.+?)\]\((.+?)\)/g
  let last = 0
  let m: RegExpExecArray | null
  const text = (t: string, format = 0) => ({ type: 'text', text: t, format, style: '', mode: 'normal', detail: 0, version: 1 })
  while ((m = re.exec(src))) {
    if (m.index > last) out.push(text(src.slice(last, m.index)))
    if (m[1]) out.push(text(m[1], 1))
    else out.push({ ...base, version: 3, type: 'link', fields: { url: m[3], newTab: false, linkType: 'custom' }, children: [text(m[2])] })
    last = m.index + m[0].length
  }
  if (last < src.length) out.push(text(src.slice(last)))
  return out
}

export const p = (s: string): Node => ({ ...base, type: 'paragraph', textFormat: 0, textStyle: '', children: inline(s) })
export const h2 = (s: string): Node => ({ ...base, type: 'heading', tag: 'h2', children: inline(s) })
export const ul = (items: string[]): Node => ({
  ...base,
  type: 'list',
  listType: 'bullet',
  start: 1,
  tag: 'ul',
  children: items.map((s, i) => ({ ...base, type: 'listitem', value: i + 1, children: inline(s) })),
})
export const block = (blockType: string, fields: Record<string, unknown>): Node => ({
  type: 'block',
  version: 2,
  format: '',
  fields: { id: randomUUID().replace(/-/g, '').slice(0, 24), blockName: '', blockType, ...fields },
})
export const doc = (...children: Node[]) => ({ root: { ...base, type: 'root', children } })
