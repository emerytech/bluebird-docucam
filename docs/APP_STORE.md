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

## What only you can do (Apple account)

I can write and sign‑verify the code, but these live in **your** Apple Developer account / App Store
Connect and need your login:

### 1. Certificates
Create two (Xcode ▸ Settings ▸ Accounts ▸ *Manage Certificates…* ▸ **+**, or on the portal):
- **Apple Distribution** — signs the `.app`
- **Mac Installer Distribution** (a.k.a. *3rd Party Mac Developer Installer*) — signs the `.pkg`

Confirm they’re present:
```bash
security find-identity -v | grep -E "Apple Distribution|Mac Developer Installer"
```
> Today this machine only has *Apple Development* + *Developer ID Application* — neither can sign a
> Mac App Store build, which is why the `.pkg` step is blocked until these exist.

### 2. App ID + provisioning profile
- Register / confirm the App ID **`com.emerytech.BlueBirdDocuCam`** for **macOS**
  (In‑App Purchase is enabled by default — no extra capability to toggle).
- Create a **Mac App Store** distribution provisioning profile for that App ID, download it, and note
  its path for `MAS_PROFILE`.

### 3. App record (App Store Connect ▸ Apps ▸ **+**)
- **Name:** `BlueBird DocuCam`   ·   **Subtitle:** `Document Camera & PDF Scanner`
- **Bundle ID:** `com.emerytech.BlueBirdDocuCam`   ·   **SKU:** `bluebird-docucam`
- **Category:** Education

### 4. Subscriptions — product IDs must match the code exactly
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

### 5. Listing bits
- **Privacy label:** *Data Not Collected* (the app collects nothing; camera stays on‑device).
- Short **privacy policy** URL (required for subscriptions).
- **Screenshots** — lead with **iPhone/iPad as a document camera** (the headline feature), then
  PDF scan, annotation, zoom.
- **Review notes:** “No account required — subscription only. A free, identical build is also
  distributed on GitHub. Educators receive a 50 % Offer Code on request.”

---

## Build + upload (once the cert/profile/products exist)

```bash
MAS_APP_CERT="Apple Distribution: Taylor Emery (XK6QP975ZQ)" \
MAS_INSTALLER_CERT="3rd Party Mac Developer Installer: Taylor Emery (XK6QP975ZQ)" \
MAS_PROFILE="$HOME/Downloads/BlueBird_DocuCam_MAS.provisionprofile" \
./build.sh --mas
# → BlueBird-DocuCam-MAS.pkg
```

Upload with an App Store Connect API key (yours live in `~/.appstoreconnect/` and `~/Developer/p8/`):
```bash
xcrun altool --upload-app -f BlueBird-DocuCam-MAS.pkg -t macos \
      --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```
…or just drag the `.pkg` into **Transporter.app**.

> **Bump the build number every upload:** raise `CFBundleVersion` in `Info.plist`
> (`CFBundleShortVersionString` only when the marketing version changes).

Without the three `MAS_*` vars, `./build.sh --mas` still runs — it produces an **ad‑hoc, sandboxed,
local‑verify** build (used to confirm the App Store variant compiles and sandboxes cleanly). That
build can’t load StoreKit products (no real App Store behind it), so its paywall sits at
“Loading plans…”. That’s expected.

## Testing the subscription
- **Sandbox tester** (ASC ▸ Users and Access ▸ Sandbox) signed into the Mac’s App Store, **or**
- **TestFlight** for macOS.
- A plain `swiftc` build can’t inject a local `.storekit` config (that’s an Xcode‑scheme feature), so
  real product/trial/purchase flows are tested through Sandbox/TestFlight, not the local `--mas` build.

---

## Status
- ✅ Code: `#if APP_STORE` sandbox + StoreKit gate + paywall; Ko‑fi/self‑updater stripped. Both
  variants compile; the `--mas` app is universal, sandboxed, and signs cleanly (ad‑hoc verified).
- ⏳ Blocked on you: Apple Distribution + Installer certs, MAS provisioning profile, the ASC app
  record + the two subscription products. Then the `.pkg` build + upload above is a one‑liner.
