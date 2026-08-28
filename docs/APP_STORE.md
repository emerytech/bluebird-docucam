# BlueBird DocuCam — Mac App Store

The App Store build is the **same app** as the free GitHub version, compiled with `-D APP_STORE`.
That flag:

- turns on the **App Sandbox** (`entitlements-mas.plist`),
- gates the whole app behind an **auto‑renewing subscription** (a 30‑day free trial counts as
  active) via **StoreKit 2** + a paywall window,
- **removes** the Ko‑fi links and the in‑app self‑updater (the App Store handles updates).

Everything else — camera, zoom/pan, freeze, snapshot, PDF scanner, annotation, Continuity Camera —
is identical to the GitHub build.

> **Positioning:** the GitHub release is free and open. The App Store version is paid, aimed at
> non‑technical buyers who’d rather tap *Get* than download a DMG. That’s allowed; just be upfront
> about it in the review notes.

---

## Signing (✅ done — 2026-08-28)

The certificates, App ID, and provisioning profile are **created and verified** (a real signed `.pkg`
builds from them). Signing material lives in `~/.config/bluebird/docucam-mas/` (private keys + `.cer`
files + the `.provisionprofile`); the two identities are imported in the login keychain.

- **`3rd Party Mac Developer Application: Taylor Emery (XK6QP975ZQ)`** — signs the `.app`
- **`3rd Party Mac Developer Installer: Taylor Emery (XK6QP975ZQ)`** — signs the `.pkg`
- App ID **`com.emerytech.BlueBirdDocuCam`** (explicit) registered.
- Provisioning profile **“BlueBird DocuCam Mac App Store”** (App Store type, expires 2027-08-28).

> These are the **legacy Mac-specific** distribution types, chosen deliberately so they don't consume
> an "Apple Distribution" cert slot — the EAS/Expo certs used by your other apps are untouched.

Confirm any time:
```bash
security find-identity -v | grep "3rd Party Mac Developer"
```

`./build.sh --mas` already defaults to these (see below), so no env vars are needed on this Mac.

---

## What only you can do (App Store Connect)

### 1. App record (App Store Connect ▸ Apps ▸ **+**)
- **Name:** `BlueBird DocuCam`   ·   **Subtitle:** `Document Camera & PDF Scanner`
- **Bundle ID:** `com.emerytech.BlueBirdDocuCam`   ·   **SKU:** `bluebird-docucam`
- **Category:** Education

### 2. Subscriptions — product IDs must match the code exactly
In *Monetization ▸ Subscriptions*, make one subscription group (e.g. **“BlueBird DocuCam”**) with:

| Plan | **Product ID (exact)** | Price | Intro offer |
|------|------------------------|-------|-------------|
| Monthly | `com.emerytech.BlueBirdDocuCam.monthly` | **$0.99 / month** | 30‑day free trial (new subscribers) |
| Yearly  | `com.emerytech.BlueBirdDocuCam.yearly`  | **$4.99 / year**  | 30‑day free trial (new subscribers) |

> The code reads these two IDs from `subProductIDs` in `main.swift`. If you rename them in ASC, rename
> them there too. The paywall auto‑sorts by price, so **Monthly** shows first.

**Educator 50 % off** → *Offer Codes* on the subscription: create a 50 %‑off code batch, email codes to
educators who ask. They redeem in App Store ▸ *Redeem Gift Card or Code*. (Auto‑renewing subs support
Offer Codes natively — no separate build.)

### 3. Listing bits
- **Privacy label:** *Data Not Collected* (the app collects nothing; camera stays on‑device).
- Short **privacy policy** URL (required for subscriptions).
- **Screenshots** — lead with **iPhone/iPad as a document camera** (the headline feature), then
  PDF scan, annotation, zoom.
- **Review notes:** “No account required — subscription only. A free, identical build is also
  distributed on GitHub. Educators receive a 50 % Offer Code on request.”

---

## Build + upload

On this Mac (certs + profile already in place):
```bash
./build.sh --mas          # → BlueBird-DocuCam-MAS.pkg  (real, signed, uploadable)
```
`build.sh` defaults `MAS_APP_CERT` / `MAS_INSTALLER_CERT` / `MAS_PROFILE` to the assets created above;
override any of them via env or `.env` if they ever move. The first signing of a session may pop a
keychain prompt for the new key — click **Always Allow**. If the certs/profile aren't found, the
`--mas` build falls back to an ad-hoc sandbox build (local verify only) instead of failing.

Upload with an App Store Connect API key (yours live in `~/.appstoreconnect/` and `~/Developer/p8/`):
```bash
xcrun altool --upload-app -f BlueBird-DocuCam-MAS.pkg -t macos \
      --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```
…or just drag the `.pkg` into **Transporter.app**.

> **Bump the build number every upload:** raise `CFBundleVersion` in `Info.plist`
> (`CFBundleShortVersionString` only when the marketing version changes).

On a machine **without** the certs/profile, `./build.sh --mas` falls back to an **ad‑hoc, sandboxed,
local‑verify** build (confirms the variant compiles and sandboxes cleanly). That build can’t load
StoreKit products (no real App Store behind it), so its paywall sits at “Loading plans…”. Expected.

## Testing the subscription
- **Sandbox tester** (ASC ▸ Users and Access ▸ Sandbox) signed into the Mac’s App Store, **or**
- **TestFlight** for macOS.
- A plain `swiftc` build can’t inject a local `.storekit` config (that’s an Xcode‑scheme feature), so
  real product/trial/purchase flows are tested through Sandbox/TestFlight, not the local `--mas` build.

---

## Status
- ✅ Code: `#if APP_STORE` sandbox + StoreKit gate + paywall; Ko‑fi/self‑updater stripped.
- ✅ Signing: Mac App Distribution + Mac Installer Distribution certs, App ID, and Mac App Store
  provisioning profile all created and verified end-to-end — **a real signed
  `BlueBird-DocuCam-MAS.pkg` builds** (app signed + sandboxed + profile embedded; `.pkg` installer-signed).
- ⏳ Remaining (App Store Connect, your login): create the app record, the two auto-renew
  subscription products (+ 30-day trial + educator Offer Code), fill the listing/privacy/screenshots,
  then upload the `.pkg` and submit for review.
