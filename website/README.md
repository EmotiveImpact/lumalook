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

Once the domain is live, set `LLPrivacyPolicyURL` and `LLTermsOfUseURL` in the
app's Info.plist (see `LumaLegal` in `Screens/MoreScreens.swift`) to
`https://<domain>/privacy` and `https://<domain>/terms`, and use
`https://<domain>/support` as the App Store support URL.

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
