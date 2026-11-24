import { StaticPage, staticMetadata } from '@/components/StaticPage'

export const dynamic = 'force-static'
export const metadata = staticMetadata('support', '/support')
export default function SupportPage() {
  return <StaticPage name="support" />
}
