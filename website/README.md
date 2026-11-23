# LumaLook website

The marketing site for the app, plus the privacy policy, terms and support
pages the App Store listing links to. Plain HTML and CSS with a few lines of
script: no build step, no framework, no cookies, no analytics.

```
vercel.json       at the repository root: serves website/, clean URLs
                  (/privacy, /terms, /support), headers, and skips builds
                  on branches that have no website/ folder
website/
  index.html      landing page
  privacy.html    privacy policy (the app's privacy link points here)
  terms.html      terms of use, including the subscription disclosure
  support.html    help and contact (the App Store support URL)
  founders.html   Founding Creators application form (posts to /api/founders)
  mission.html    why LumaLook exists, the Shirley card history, Emotive Impact
  partners.html   ways to partner, Awards teaser, enquiry form (posts to /api/partners)
  showcase.html   creators' work, shared with permission (placeholders until filled)
  blog.html       blog index; posts live in blog/<slug>.html
  404.html
  assets/
    site.css      Night Lab tokens and every style
    site.js       App Store link, support address, pricing toggle
    fonts/        Inter, self-hosted (SIL Open Font Licence, OFL.txt)
    img/screens/  screenshots from the app's simulator preview (CI)
    img/photos/   the app's bundled Unsplash sample photos
    img/hero/     the hero portrait, graded with the app's CP3513 look
    img/looks/    sample photos graded with the app's real film LUTs,
                  each beside its original for the hold-to-compare cards
    img/faces/    small face crops for the statement line
```

## Run it locally

```sh
cd website
python3 -m http.server 8000
# open http://localhost:8000
```

## Put it live

**Vercel (recommended, and how it runs today).** The project `lumalook`
imports `EmotiveImpact/lumalook` with the Root Directory left blank. The
root `vercel.json` sets the output directory to `website`, with no install
or build step. Its `ignoreCommand` (`test ! -d website`) skips any branch
without the site, so app pull requests don't get a failed Vercel check. The
same settings are saved in the Vercel project, because branches made before
the site existed don't have the root `vercel.json`.
Every push to `master` then redeploys, and pull requests get preview links.
Add the domain under Project, Settings, Domains.

**Caching.** `site.css` and `site.js` are revalidated on every visit; images
and fonts are cached for a day. Browsers that saw an earlier version may
still hold old copies, so when you change `site.css`, `site.js` or replace an
image at the same path, bump its `?v=` value in the HTML (every page links
the stylesheet and script).

**GitHub Pages** also works because the repository is public: Settings, Pages,
deploy from a GitHub Actions workflow that uploads the `website` folder.

The site lives at **https://lumalook.app** (registered on Spaceship, DNS
pointing at Vercel; `www.lumalook.app` and `lumalook.vercel.app` redirect to
it). The app's privacy and terms links (`LumaLegal` in
`Screens/MoreScreens.swift`) point at `https://lumalook.app/privacy` and
`https://lumalook.app/terms`. In App Store Connect use
`https://lumalook.app/privacy` as the privacy policy URL and
`https://lumalook.app/support` as the support URL. Canonical links, `og:url`
and `sitemap.xml` all use the same domain.

## Launch day

1. In `assets/site.js`, set `APP_STORE_URL` to the app's App Store link. Every
   "Coming soon" button turns into a download link.
2. Swap the yellow download button for Apple's official
   "Download on the App Store" badge if you want the badge artwork
   (Apple requires the official file, unaltered).
3. Add `og:url` and a `<link rel="canonical">` with the final domain to each
   page's head.

## Keeping it true

- Prices on the page are the approved US prices: Pro $34.99 a year with a
  7-day trial or $5.99 a month, Lifetime $79.99 with every pack, packs $2.99
  and $3.99. Change `index.html` and `terms.html` together if they move.
- Look and pack counts (123 looks, 11 packs) come from
  `LumaLook/Engine/LookPacks.swift`.
- The graded photos in `img/hero` and `img/looks` were made by applying the
  app's own `.cube` files (`LumaLook/Resources/FilmLUTs`) to the sample
  photos, so each card shows exactly what that look does. If a look's LUT
  changes, regrade its card. The hero's wide version extends the red wall
  of the original portrait so it fills a landscape frame.
- Screens come from the Preview workflow (`.github/workflows/preview.yml`),
  converted to WebP. Re-take them when the app's look changes.
- The privacy policy describes what the app does today: on-device editing,
  captions on device where the language allows, RevenueCat for purchases,
  no analytics. Update it before adding any SDK that collects data.

## Lifetime on the web (Polar) and the waitlist (Resend)

**Lifetime.** The Lifetime card's "Buy Lifetime" button is a Polar checkout
link (organisation "Emotive", slug `emotive-impact`; product "LumaLook
Lifetime", $79.99 / £64.99, one-off). Polar is the merchant of record, so it
charges tax and sends the receipt. After paying, buyers land on `/thanks`.
Polar only takes real payments once the organisation passes Polar's account
review (identity check, payout account, support email: Finance, then Account
in the Polar dashboard).

**How a web buyer gets Lifetime in the app (planned, not built yet).** The
purchase is tied to the email paid with. In the app, You, then "Restore web
purchase", asks for that email; a small server route emails a one-time code
(Resend), checks Polar for a paid LumaLook Lifetime order on that email, then
grants the RevenueCat entitlement `pro` as a lifetime promotional entitlement
to the app's RevenueCat user (REST API, secret key kept on the server). Being
an email sign-in rather than a licence key keeps it inside App Store guideline
3.1.3(b) (multiplatform services), and Lifetime is also sold as an in-app
purchase. The app itself must not link to or mention the web price, except in
storefronts where Apple allows external purchase links (such as the US).

**Waitlist.** The form in the closing band posts to `/api/waitlist`
(`api/waitlist.js` at the repo root, a Vercel function). It saves the address
as a Resend contact in the "LumaLook waitlist" segment and sends one
confirmation from `hello@lumalook.app`. A repeat signup gets no second email.
The form hides itself once `APP_STORE_URL` is set in `site.js`.
Vercel env: `RESEND_API_KEY`, `RESEND_WAITLIST_SEGMENT_ID`, `WAITLIST_REPLY_TO`.

## Founding Creators applications

`/founders` is an application form for the Founding Creators test group
(people who test builds first, shape how skin renders, and get Lifetime free).
It posts to `/api/founders` (`api/founders.js`), which:

1. emails the whole application to `FOUNDERS_NOTIFY_TO` (falls back to
   `WAITLIST_REPLY_TO`), with reply-to set to the applicant;
2. saves the applicant as a Resend contact, in the "LumaLook Founding
   Creators" segment when `RESEND_FOUNDERS_SEGMENT_ID` is set;
3. sends the applicant one copy of what they sent, only the first time that
   address is seen, so the form can't be used to flood an inbox.

The Monk skin-tone answer is optional and is dropped unless its consent box is
ticked (see `privacy.html#founders`). The swatches are the Monk Skin Tone
Scale by Ellis Monk, CC BY 4.0, credited in the page footer.
