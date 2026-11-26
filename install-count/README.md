From this directory, run the following with Wrangler authenticated to the DocuCam Cloudflare account to see the number of participating direct installations active today or in the preceding 29 UTC dates.

    wrangler d1 execute docucam-install-count --remote --file active.sql

One installation ID belongs to a local user profile. Resetting app data can create a new ID. Older releases, offline installations and users who disable participation in Settings are absent. The public check-in accepts self-reported IDs and cannot establish purchase status or a download source.

The worker exposes only POST /v1/check-in. Apply schema.sql to the bound D1 database before deploying with wrangler deploy. A daily scheduled job removes expired entries.
