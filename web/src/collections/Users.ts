import { APIError, type CollectionConfig } from 'payload'

export const Users: CollectionConfig = {
  slug: 'users',
  admin: {
    useAsTitle: 'email',
  },
  auth: {
    maxLoginAttempts: 5,
    lockTime: 15 * 60 * 1000,
  },
  access: {
    // Only signed-in editors can add more editors.
    create: ({ req }) => Boolean(req.user),
  },
  hooks: {
    beforeOperation: [
      ({ operation, req }) => {
        // Payload's "create first user" screen skips access control. On a public site that would
        // let a stranger claim the admin, so it only works over the web when ADMIN_SIGNUP_OPEN=true.
        // The seed script (local API) still creates the first admin from SEED_ADMIN_EMAIL.
        if (operation === 'create' && !req.user && req.payloadAPI !== 'local' && process.env.ADMIN_SIGNUP_OPEN !== 'true') {
          throw new APIError('Sign-up is closed.', 403)
        }
      },
    ],
  },
  fields: [],
}
