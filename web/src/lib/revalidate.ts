import { revalidatePath } from 'next/cache'

// Pages are built ahead of time. When something changes in the admin, rebuild
// only the pages that show it. Outside a Next request (seed script, CLI)
// revalidatePath throws, which is fine to ignore.
export function revalidate(paths: string[]) {
  for (const p of paths) {
    try {
      revalidatePath(p)
    } catch {
      /* not in a Next.js request */
    }
  }
}
