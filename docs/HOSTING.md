# Website hosting

The production website is served by Cloudflare Workers Static Assets at
https://swiftycrow.pangmo5.dev/. GitHub Actions assembles the site and deploys
it with the pinned Wrangler version in `.github/workflows/deploy-site.yml`.
`wrangler.jsonc` owns the Worker name, asset directory, and custom domain.

## Deployment authentication

Configure `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` as GitHub Actions
secrets for this repository (or its `cloudflare` environment). The token must
allow Worker deployments and custom-domain routing for the intended account
and the `pangmo5.dev` zone. Do not commit credentials.

## Website and release updates

Run the **Deploy site** workflow on `main` to publish website changes. Each
artifact includes the signed `appcast.xml` from GitHub Releases; deployment
must preserve that feed. The release workflow also publishes the updated feed.
App binaries continue to download directly from GitHub Releases.

The existing installed apps still use `https://pangmo5.dev/SwiftyCrow/appcast.xml`.
The root website owns a permanent redirect from `/SwiftyCrow/*` to this site's
root, preserving the remaining path and query. Keep that redirect: migration
does not require users to install an intermediate app release. New builds use
`https://swiftycrow.pangmo5.dev/appcast.xml` directly via `SUFeedURL` in
`Project.swift`. Keep the old redirect for every previously installed version.

## Local verification

After assembling the same site artifact as CI into `dist/`, run:

```sh
npx wrangler@4.131.2 dev
npx wrangler@4.131.2 deploy --dry-run
```

Wrangler resolves directory indexes and canonical HTML paths. Verify the root,
documentation, media, and `appcast.xml`; a missing asset must return 404.
The `_headers` file makes the appcast revalidate on every request.

## Domain cutover

Deploy and verify this subdomain before deploying the redirects on
`pangmo5.dev`. Keep the `PangMo5.github.io` custom-domain setting and project
Pages compatibility endpoints while old `github.io` URLs remain in use.
Verify those redirects after any Pages or DNS setting change.
