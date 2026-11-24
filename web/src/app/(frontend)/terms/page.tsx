import { StaticPage, staticMetadata } from '@/components/StaticPage'

export const dynamic = 'force-static'
export const metadata = staticMetadata('terms', '/terms')
export default function TermsPage() {
  return <StaticPage name="terms" />
}
