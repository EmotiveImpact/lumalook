import { getPayload } from 'payload'
import config from '@payload-config'

// Server only: use inside getStaticProps / route handlers.
export const payload = () => getPayload({ config })
