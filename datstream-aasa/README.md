# DATStream AASA Host

GitHub Pages site for hosting `apple-app-site-association` so the
DATStream iOS app's Universal Link route works with Meta AI registration.

## Setup

1. Push this repo to GitHub (any public repo)
2. Settings → Pages → Source: `Deploy from a branch`, Branch: `main`, Folder: `/ (root)`
3. Wait ~1 minute for the site to publish
4. Verify the AASA is reachable at:
   `https://<USERNAME>.github.io/<REPO>/.well-known/apple-app-site-association`
5. Apple's CDN must be able to fetch and validate it. Test:
   `curl -i https://app-site-association.cdn-apple.com/a/v1/<USERNAME>.github.io`
