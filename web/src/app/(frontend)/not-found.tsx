import { StaticPage, staticMetadata } from '@/components/StaticPage'

export const metadata = staticMetadata('notfound', '/404')
export default function NotFound() {
  return <StaticPage name="notfound" />
}
