import { StaticPage, staticMetadata } from '@/components/StaticPage'

export const dynamic = 'force-static'
export const metadata = staticMetadata('index', '/')
export default function Home() {
  return <StaticPage name="index" />
}
