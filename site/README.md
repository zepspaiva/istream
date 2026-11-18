# couchwire.io

The landing page: one static file, `index.html`, no build step. Open it in a browser to preview.

Before going live:

- Set `WAITLIST_ENDPOINT` near the end of `index.html` to a form endpoint (any waitlist or form service that accepts a POST). Until then the form says the waitlist isn't open and sends nothing.
- Host the folder on any static host (GitHub Pages, Cloudflare Pages, Netlify) and point couchwire.io at it.
