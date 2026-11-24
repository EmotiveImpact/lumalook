import type { Metadata } from 'next'
import { notFound } from 'next/navigation'
import { Shell } from '@/components/Chrome'
import { PostBody } from '@/components/PostBody'
import { formatDate, mediaAlt, mediaUrl, payload } from '@/lib/payload'

export const dynamic = 'force-static'
export const dynamicParams = true

async function getPost(slug: string) {
  const p = await payload()
  const { docs } = await p.find({
    collection: 'posts',
    where: { and: [{ slug: { equals: slug } }, { _status: { equals: 'published' } }, { comingSoon: { not_equals: true } }] },
    limit: 1,
    depth: 1,
  })
  return docs[0]
}

export async function generateStaticParams() {
  const p = await payload()
  const { docs } = await p.find({ collection: 'posts', where: { _status: { equals: 'published' } }, limit: 500, depth: 0, select: { slug: true, comingSoon: true } })
  return docs.filter((d) => !d.comingSoon).map((d) => ({ slug: d.slug }))
}

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const { slug } = await params
  const post = await getPost(slug)
  if (!post) return {}
  const img = mediaUrl(post.cover as never, 'wide')
  return {
    title: post.title,
    description: post.excerpt,
    alternates: { canonical: `/blog/${post.slug}` },
    openGraph: { type: 'article', title: post.title, description: post.excerpt, url: `/blog/${post.slug}`, publishedTime: post.publishedAt || undefined, images: img ? [img] : undefined },
  }
}

export default async function PostPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params
  const post = await getPost(slug)
  if (!post) notFound()
  const cover = mediaUrl(post.cover as never, 'wide')
  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'BlogPosting',
    headline: post.title,
    description: post.excerpt,
    datePublished: post.publishedAt,
    dateModified: post.updatedAt,
    image: cover ? new URL(cover, 'https://lumalook.app').toString() : undefined,
    author: { '@type': 'Organization', name: 'Lumalook' },
    publisher: { '@type': 'Organization', name: 'Emotive Impact' },
    mainEntityOfPage: `https://lumalook.app/blog/${post.slug}`,
  }
  return (
    <Shell active="blog">
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd).replace(/</g, '\\u003c') }} />
      <section className="article-hero">
        <div className="wrap">
          <a className="back" href="/blog">&larr; Blog</a>
          <h1 className="lh grad">
            {post.headlineLight || post.headlineHeavy ? (
              <>
                <span className="l">{post.headlineLight}</span> <span className="h">{post.headlineHeavy}</span>
              </>
            ) : (
              post.title
            )}
          </h1>
          {post.lede ? <p className="lede">{post.lede}</p> : null}
          <div className="post-meta">
            <span className="cat">{post.category}</span>
            <span>{formatDate(post.publishedAt)}</span>
            {post.readTime ? <span>{post.readTime}</span> : null}
            <span>By the Lumalook team</span>
          </div>
        </div>
      </section>
      {cover ? (
        <div className="article-cover">
          <figure>
            <img src={cover} alt={mediaAlt(post.cover as never)} />
            {post.coverCaption ? <figcaption>{post.coverCaption}</figcaption> : null}
          </figure>
        </div>
      ) : null}
      <article className="article">
        <div className="wrap prose">
          {post.body ? <PostBody data={post.body as never} /> : null}
          {post.credits ? <p className="tone-cap credits">{post.credits}</p> : null}
        </div>
      </article>
    </Shell>
  )
}
