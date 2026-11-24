import { StaticPage, staticMetadata } from '@/components/StaticPage'

export const dynamic = 'force-static'
export const metadata = staticMetadata('thanks', '/thanks')
export default function ThanksPage() {
  return <StaticPage name="thanks" />
}
