import { StaticPage, staticMetadata } from '@/components/StaticPage'

export const dynamic = 'force-static'
export const metadata = staticMetadata('founders', '/founders')
export default function FoundersPage() {
  return <StaticPage name="founders" />
}
