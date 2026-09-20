# Distribution Runbook — Notarized Direct Sale + Licensing

Go-to-market path for OpenWhisperer: **direct download, notarized Developer ID DMG, sold via a
merchant-of-record with a license key.** The Mac App Store is not viable (sandbox forbids AX text
injection, hook writes to `~/.claude`/`~/.codex`, out-of-container model downloads, and the
external-CLI dependency — see the distribution analysis). This doc is the concrete how-to.

Status: **draft / not yet executed.** Uncommitted. `build-dmg.sh` already contains the full
`OW_NOTARIZE` path; what's missing is (a) the $99 enrollment + a Developer ID cert + stored
credentials, and (b) the licensing/update code, which does not exist yet.

---

## Phase 1 — Apple Developer enrollment + signing identity (one-time)

1. **Enroll** in the Apple Developer Program ($99/yr) → <https://developer.apple.com/programs/enroll/>.
   Individual enrollment may require ID verification; allow 24–48 h.
2. **Create a Developer ID Application certificate.** This machine is CLT-only (no full Xcode), so
   use the manual CSR route — you do *not* need Xcode:
   - Keychain Access → **Certificate Assistant → Request a Certificate from a Certificate Authority**.
     Enter your Apple ID email, "Saved to disk", Continue → produces a `.certSigningRequest`.
     (This generates the cert's private key in your **login** keychain — keep that keychain; the
     private key is what signs every build.)
   - <https://developer.apple.com/account> → Certificates → **+** → **Developer ID Application** →
     upload the CSR → download the `.cer` → double-click to install into the login keychain.
3. **Confirm the identity string** macOS will use to sign:
   ```bash
   security find-identity -v -p codesigning
   # → "Developer ID Application: Your Name (TEAMID)"
   ```
4. **Grab your Team ID**: <https://developer.apple.com/account> → Membership details (10-char, also
   the `(TEAMID)` suffix above).
5. **Create an app-specific password** for the notary service (NOT your Apple ID password):
   <https://appleid.apple.com> → Sign-In & Security → App-Specific Passwords → **+**.

> Note: the audio-input entitlement and `NSMicrophoneUsageDescription` are already in place, and
> hardened runtime does **not** break the app's Accessibility/CGEvent typing — those are TCC runtime
> grants, not hardened-runtime entitlements, so no entitlement changes are needed.

---

## Phase 2 — Store notary credentials + build a notarized DMG

1. **Store the credential profile once** (keychain-backed; the build script reads it by name):
   ```bash
   xcrun notarytool store-credentials "openwhisperer-notary" \
       --apple-id "you@example.com" \
       --team-id "TEAMID" \
       --password "xxxx-xxxx-xxxx-xxxx"   # the app-specific password
   ```
   (Alternative: an App Store Connect API key via `--key/--key-id/--issuer` instead of the
   app-specific password. Either works; the password route is simpler for a solo dev.)

2. **Build the release** — this is the only command you run per release:
   ```bash
   cd app
   OW_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   OW_NOTARIZE=1 \
   OW_NOTARIZE_PROFILE="openwhisperer-notary" \
   ./build-dmg.sh
   ```
   The script already: signs the nested `jq` with hardened runtime + secure timestamp, signs the
   outer bundle with the entitlements, builds the DMG, then `notarytool submit --wait` +
   `stapler staple` + `stapler validate`. ([build-dmg.sh](../app/build-dmg.sh) lines 101–154.)

3. **Verify the result** (do this on the build machine AND a clean second Mac / fresh user):
   ```bash
   xcrun stapler validate .build/OpenWhisperer-1.5.1.dmg
   spctl -a -vvv -t install .build/OpenWhisperer-1.5.1.dmg
   #  → source=Notarized Developer ID   (this is the pass condition)
   codesign --verify --deep --strict --verbose=2 .build/OpenWhisperer.app
   ```

### Gotchas
- **One-time re-grant.** Switching identity (`OpenWhisperer Dev` self-signed → Developer ID) changes
  the designated requirement, so the **first** Developer-ID build forces you (and every existing
  user) to re-grant Accessibility + Microphone once. After that it's stable forever — the Developer
  ID requirement pins to your **Team ID**, so grants survive even cert *renewal*.
- **Nested code.** The only nested Mach-O is `jq` (the script signs it). The SwiftPM `*.bundle`
  resources are statically linked / resource-only, so no per-bundle signing is needed. If
  notarization ever rejects for "unsigned nested code", run `spctl`/`codesign --deep --strict` to
  find the offender and sign it before the outer bundle.
- If `notarytool submit` returns `Invalid`, inspect the log:
  `xcrun notarytool log <submission-id> --keychain-profile openwhisperer-notary`.

---

## Phase 3 — Payments + license gating (Lemon Squeezy)

Use a **merchant-of-record** so you never touch global VAT/sales tax. Lemon Squeezy or Paddle, both
~5% + $0.50/txn. Lemon Squeezy has a built-in license-key API and is simplest for a solo macOS dev.

### 3a. Store setup (no code)
1. Create a Lemon Squeezy store + a **single-payment** product for OpenWhisperer.
2. Enable **License keys** on the product variant; set an **activation limit** (e.g. 3 devices).
3. On purchase the buyer is emailed a key like `38B1460A-...-4B2D`. The DMG download link can be the
   product's delivery URL or a link to your site / GitHub Release.

### 3b. App-side activation (new code — does not exist yet)
Three endpoints (`POST`, no auth header needed — the key is the secret):
- Activate (first launch): `https://api.lemonsqueezy.com/v1/licenses/activate`
  body `license_key`, `instance_name` (e.g. the Mac's name) → returns `activated`, `instance.id`.
- Validate (subsequent launches): `/v1/licenses/validate` body `license_key`, `instance_id`.
- Deactivate (user removes a device): `/v1/licenses/deactivate` body `license_key`, `instance_id`.

Sketch (`LicenseManager.swift`, an actor; store key + instance_id in **Keychain**, not a flat file):
```swift
actor LicenseManager {
    struct State: Codable { var key: String; var instanceId: String; var lastValidated: Date }
    private let base = URL(string: "https://api.lemonsqueezy.com/v1/licenses")!
    private let graceDays = 7            // allow offline use before forcing re-validation

    func activate(_ key: String) async throws -> Bool {
        let r = try await post("activate", ["license_key": key,
                                            "instance_name": Host.current().localizedName ?? "Mac"])
        guard r["activated"] as? Bool == true,
              let inst = (r["instance"] as? [String: Any])?["id"] as? String else { return false }
        try Keychain.save(State(key: key, instanceId: inst, lastValidated: Date()))
        return true
    }

    /// Returns true if licensed. Offline-tolerant: within graceDays of last success, trust the cache.
    func isLicensed() async -> Bool {
        guard var s = try? Keychain.load() else { return false }
        do {
            let r = try await post("validate", ["license_key": s.key, "instance_id": s.instanceId])
            let ok = r["valid"] as? Bool == true
            if ok { s.lastValidated = Date(); try? Keychain.save(s) }
            return ok
        } catch {                                   // offline → fall back to grace window
            return Date().timeIntervalSince(s.lastValidated) < Double(graceDays) * 86_400
        }
    }
}
```
- **Gate in `AppDelegate`** at launch: if `!isLicensed()`, show an Activate window and either block
  dictation or run a time-limited trial. For a menubar app, an "Activate License…" item + an
  unlicensed nag is enough.
- **Optional 7-day trial**: store first-launch date in Keychain; require a key after it lapses.
- **Reality check**: client-side checks are bypassable. For an $8.99–$24.99 indie tool that's fine —
  don't over-engineer. If you want offline verification without a network call, Lemon Squeezy issues
  Ed25519-signed license *tokens* you can verify locally with a bundled public key.

---

## Phase 4 — Auto-updates (Sparkle)

Outside the App Store you ship your own updater. Sparkle (MIT) is the standard.
1. Add Sparkle to `app/Package.swift` (`.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.x")`).
2. Generate the EdDSA key pair with Sparkle's `generate_keys` (private key → Keychain, public key →
   Info.plist `SUPublicEDKey`).
3. Info.plist: `SUFeedURL = https://openwhisperer.com/appcast.xml`, `SUPublicEDKey = <pub>`.
4. Per release: produce a **notarized zip of the .app** (Sparkle updates in place; a zip is simpler
   than a DMG for the feed — keep the DMG for the website's first-download), then
   `sign_update OpenWhisperer-1.5.1.zip` → paste the `edSignature` + `length` into a new `<item>` in
   `appcast.xml`. Sparkle verifies **both** its EdDSA signature and the Apple code signature, so the
   zip must also be Developer-ID-signed + notarized.
5. App: wire `SPUStandardUpdaterController` + a "Check for Updates…" menu item.

---

## Checklist (todo)

- [ ] Enroll in Apple Developer Program ($99) — Phase 1.1
- [ ] Create Developer ID Application cert via Keychain CSR; install to login keychain — 1.2
- [ ] Record signing-identity string + Team ID — 1.3–1.4
- [ ] Create app-specific password — 1.5
- [ ] `notarytool store-credentials "openwhisperer-notary"` — 2.1
- [ ] Run the `OW_NOTARIZE=1` release build — 2.2
- [ ] Verify with `stapler validate` + `spctl` on a clean Mac — 2.3
- [ ] Re-grant Accessibility/Mic once after identity switch — 2.gotcha
- [ ] Lemon Squeezy store + product + license keys enabled — 3a
- [ ] Build `LicenseManager` (activate/validate/deactivate, Keychain, grace window) — 3b
- [ ] Gate launch in AppDelegate (+ optional trial) — 3b
- [ ] Add Sparkle + EdDSA keys + appcast feed — Phase 4
- [ ] Decide price (note: $8.99 works but is low for the category; ~$24.99 is the market floor)

## Open questions
- Price point: $8.99 vs ~$24.99? (channel is settled; only the number is open)
- Trial or no trial before license required?
- Appcast/DMG host: openwhisperer.com vs GitHub Releases?
- Activation device limit (3? 5?)
