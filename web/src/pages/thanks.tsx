import { StaticPage } from '@/components/StaticPage'

// No React in the browser: these pages are plain HTML plus site.js.
export const config = { runtime: 'nodejs', unstable_runtimeJS: false }

export default function Page() {
  return <StaticPage name="thanks" path="/thanks" />
}
