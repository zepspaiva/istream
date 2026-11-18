# couchwire.io

Static pages, no build step. Open them in a browser to preview.

- `index.html`: the pre-launch "coming soon" page (logo, teaser, email sign-up).
- `launch.html`: the full landing page for launch (how it works, what you need, waitlist by phone and TV). Swap it in as `index.html` when Couchwire ships.

Before going live:

- Set the form endpoint in each page (`NOTIFY_ENDPOINT` in `index.html`, `WAITLIST_ENDPOINT` in `launch.html`) to any form or waitlist service that accepts a POST. Until then the forms say sign-ups aren't open and send nothing.
- Host the folder on any static host (GitHub Pages, Cloudflare Pages, Netlify) and point couchwire.io at it.
