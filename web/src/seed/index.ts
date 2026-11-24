// One-off: fills an empty database with the site's current content.
// Run with: npm run seed   (safe to re-run; it skips what already exists)
import path from 'path'
import { fileURLToPath } from 'url'
import { getPayload } from 'payload'
import config from '@payload-config'
import { block, doc, h2, p, ul } from './lexical'

const dirname = path.dirname(fileURLToPath(import.meta.url))
const img = (name: string) => path.resolve(dirname, '../../public/assets/img/looks', name)

const payload = await getPayload({ config })

async function media(file: string, alt: string) {
  const found = await payload.find({ collection: 'media', where: { alt: { equals: alt } }, limit: 1 })
  if (found.docs[0]) return found.docs[0].id
  const created = await payload.create({ collection: 'media', data: { alt }, filePath: img(file) })
  return created.id
}

async function upsertPost(slug: string, data: Record<string, unknown>) {
  const found = await payload.find({ collection: 'posts', where: { slug: { equals: slug } }, limit: 1, draft: true })
  if (found.docs[0]) return payload.logger.info(`post ${slug} exists, skipped`)
  await payload.create({ collection: 'posts', data: { slug, _status: 'published', ...data } as never })
  payload.logger.info(`post ${slug} created`)
}

const party = await media('party.webp', 'Friends at a party with deep and lighter skin, graded with a Lumalook film look')
const golden = await media('golden.webp', 'A portrait of a woman with deep skin in golden light')
const bridge = await media('bridge.webp', 'A man in an orange jacket on a bridge, graded with a film look')

await upsertPost('why-filters-turn-deep-skin-grey', {
  title: 'Why filters turn deep skin grey',
  headlineLight: 'Why filters turn',
  headlineHeavy: 'deep skin grey.',
  category: 'Colour science',
  publishedAt: '2026-11-23T12:00:00.000Z',
  readTime: '6 min read',
  featured: true,
  excerpt:
    'A contrast slider, a hidden midpoint and a channel that clips first. Here’s the maths behind ashy and orange skin, and how we took our own looks from 40 skin-true to 123.',
  lede: 'If you have deep skin, you’ve probably seen it: a filter that looks great on everyone else leaves your face flat, ashy or strangely orange. Your lighting isn’t to blame. The cause is a few lines of maths, and they can be fixed.',
  cover: party,
  coverCaption: 'One of the app’s sample photos, graded with a Lumalook film look.',
  credits: 'Oklab colour model by Björn Ottosson. Monk Skin Tone Scale by Ellis Monk, used under CC BY 4.0.',
  body: doc(
    h2('It starts with one slider'),
    p('Almost every look adds contrast. Contrast picks a midpoint, then pushes everything brighter than it up and everything darker than it down. Where that midpoint sits decides who comes off worst.'),
    p('Many photo tools apply contrast in what’s called linear light, the raw maths of the sensor rather than the brightness your eye sees. In linear light, the midpoint lands at roughly 73% of the brightness you see on screen. Deep skin lives well below that line, so a look that feels gentle on light skin drags deep skin down hard.'),
    block('statRow', {
      stats: [
        { value: '73%', label: 'where the midpoint really sits when contrast runs in linear light' },
        { value: '1 in 3', label: 'of the brightness range goes to pure black with a modest 20% contrast boost' },
        { value: 'Monk 9 and 10', label: 'the deepest tones on the scale lost all detail in our tests' },
      ],
    }),
    p('We measured this across the [Monk Skin Tone Scale](https://skintone.google), ten tones from lightest to deepest:'),
    block('toneStrip', { caption: 'The Monk Skin Tone Scale by Ellis Monk, 1 to 10.' }),
    h2('Why it goes grey, or orange'),
    p('Skin that survives the crush still gets hurt in two ways.'),
    p('**Grey.** Some looks lift the shadows by adding a little brightness to every pixel. Done in linear light, that lays a flat veil over the darkest tones. On the deepest skin it removed almost two thirds of the colour. That’s the ashy look.'),
    p('**Orange.** When contrast is applied to red, green and blue separately, blue runs out first in brown skin. What’s left gets redder and more saturated. In our tests, Monk tones 7 and 8 gained around 80% more colour and drifted towards red. That’s the orange cast.'),
    h2('An old problem in new code'),
    p('None of this is new. For decades, film and photo labs were balanced against one reference face, and it was never a dark one. Kodak improved the browns in its film only after chocolate and furniture advertisers complained. We tell that story on our [mission page](/mission). Today the bias lives in defaults: a midpoint here, an extra lift there, tuned on whoever was in front of the camera when the look was made.'),
    h2('We checked our own looks'),
    p('Before launch we put every Lumalook look through the same test: 16 portraits of Black and brown people under four kinds of light, plus the full Monk chart. We weren’t happy with what we found. Only 40 of our 133 looks kept skin true. Our own recipe looks had exactly the linear contrast problem described above.'),
    p('So we fixed it at the root, in the engine every look runs through, rather than patching looks one by one. We call it True Colour:'),
    ul([
      '**Contrast on lightness you can see.** Contrast now works on perceived lightness (using the Oklab colour model), which leaves hue and colour exactly where they were.',
      '**A soft floor, not a crush.** The deepest skin keeps its detail without being lifted to grey.',
      '**No grey veil.** No look adds flat brightness to the shadows.',
      '**Skin colour held steady.** Skin keeps its hue and stays within a narrow band of colour as a look is applied.',
      '**The sheen stays.** Highlights on skin are what make it look alive, so we protect them.',
      '**We never brighten faces for you.** Rich and deep is the goal, not lighter.',
    ]),
    h2('40 before, 123 after'),
    p('Then we ran the whole test again. Five looks that couldn’t be saved were removed from the app.'),
    block('statRow', {
      stats: [
        { value: '40 of 133', label: 'looks kept skin true before the fix' },
        { value: '123 of 128', label: 'keep skin true after it, at the default 75% strength' },
        { value: '107', label: 'stay skin-true even pushed to full strength' },
      ],
    }),
    p('The handful still short of the mark are being tuned, and every new look now goes through the same test, across all ten Monk tones, before it ships.'),
    h2('Help us check'),
    p('Numbers only go so far. We’re looking for creators to try Lumalook first, push it in the hardest light they can find and tell us where it still gets them wrong.'),
    block('button', { label: 'Become a Founding Creator', href: '/founders' }),
  ),
})

const soon = [
  ['shirley-card', 'History', 'Shirley and the card that decided what "normal" skin looked like', 'How a lab reference card shaped decades of photos, and why its echo is still in our phones.'],
  ['inside-true-colour', 'Behind the looks', 'Inside True Colour: the full test results', '16 portraits, four kinds of light and all ten Monk tones, look by look, before and after the fix.'],
  ['shooting-deep-skin-at-night', 'How to shoot', 'Shooting deep skin under neon and at night', 'Exposure, white balance and which looks to reach for when the light gets hard.'],
]
for (const [slug, category, title, excerpt] of soon) {
  await upsertPost(slug, { title, category, excerpt, comingSoon: true, publishedAt: '2026-11-23T11:00:00.000Z' })
}

const examples = [
  { creatorName: 'Creator name', handle: '@handle', city: 'City', look: 'Look name', image: golden, shape: 'tall', order: 1 },
  { creatorName: 'Creator name', handle: '@handle', city: 'City', look: 'Film look', image: bridge, shape: 'normal', order: 2 },
]
const existing = await payload.find({ collection: 'showcase', where: { isExample: { equals: true } }, limit: 1 })
if (!existing.docs.length) {
  for (const e of examples) await payload.create({ collection: 'showcase', data: { ...e, isExample: true, permission: true, published: true } as never })
  payload.logger.info('showcase examples created')
}

const email = process.env.SEED_ADMIN_EMAIL
const password = process.env.SEED_ADMIN_PASSWORD
if (email && password) {
  const users = await payload.find({ collection: 'users', limit: 1 })
  if (!users.docs.length) {
    await payload.create({ collection: 'users', data: { email, password } })
    payload.logger.info(`admin ${email} created`)
  }
}

payload.logger.info('seed done')
process.exit(0)
