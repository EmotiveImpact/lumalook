import { StaticPage, staticMetadata } from '@/components/StaticPage'

export const dynamic = 'force-static'
export const metadata = staticMetadata('privacy', '/privacy')
export default function PrivacyPage() {
  return <StaticPage name="privacy" />
}
