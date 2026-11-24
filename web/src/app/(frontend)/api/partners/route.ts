import handler from '@/server/partners'
import { run } from '@/server/run'

export const dynamic = 'force-dynamic'
export const POST = (req: Request) => run(handler, req)
export const GET = (req: Request) => run(handler, req)
