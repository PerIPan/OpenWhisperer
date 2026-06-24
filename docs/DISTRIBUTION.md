# Distribution & Notarization — OpenWhisperer

**Channel:** notarized **direct download** (Developer ID + Hardened Runtime), hosted on GitHub
Releases / openwhisperer.com. **Not** the Mac App Store — the App Sandbox forbids this app's core
mechanics (injecting transcribed keystrokes into other apps via Accessibility/CGEvent, and writing
hook scripts into `~/.claude` / `~/.codex`). No rewrite changes that; notarized direct download is
the correct and only viable channel.

The build script (`app/build-dmg.sh`) already implements the full flow. What's gated on you is an
Apple Developer account and a one-time credential setup.

## One-time setup (needs a paid Apple Developer account — $99/yr)

1. **Developer ID Application certificate** in your login keychain
   (Xcode → Settings → Accounts → Manage Certificates → +, or developer.apple.com). Confirm:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
2. **notarytool credential profile** (stores your Apple ID + team + an app-specific password):
   ```bash
   xcrun notarytool store-credentials "OpenWhispererNotary" \
       --apple-id "you@example.com" --team-id "ABCDE12345" \
       --password "<app-specific-password>"   # appleid.apple.com → Sign-In & Security → App-Specific Passwords
   ```

## Cut a release

```bash
cd app
OW_SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)" \
OW_NOTARIZE=1 \
OW_NOTARIZE_PROFILE="OpenWhispererNotary" \
./build-dmg.sh
```

This release build: signs the bundled `jq` (nested Mach-O) and the `.app` with Hardened Runtime +
`Resources/OpenWhisperer.entitlements` + secure timestamp, builds `OpenWhisperer-1.5.0.dmg`,
submits to notarytool (`--wait`), then staples + validates the ticket. Output:
`app/.build/OpenWhisperer-1.5.0.dmg`.

### Before the live submit (recommended dry run)
The `OW_NOTARIZE` codesign branch is exercised for the first time on the release machine. Prove the
nested-then-outer signing works **before** the Apple round-trip:
```bash
OW_SIGN_IDENTITY="Developer ID Application: …" ./build-dmg.sh   # no OW_NOTARIZE → sign only
codesign --verify --deep --strict --verbose=2 .build/Open\ Whisperer.app
```
Then re-run with `OW_NOTARIZE=1` for the real submission.

## Entitlements (already correct — no change needed)

`Resources/OpenWhisperer.entitlements` declares only `com.apple.security.device.audio-input`. The app
is intentionally **not sandboxed**. Accessibility + CGEvent posting are TCC permissions granted at
runtime (not entitlements). The three Info.plist purpose strings are present: Microphone,
Accessibility, **SpeechRecognition** (hands-free keyword detection under Hardened Runtime).

## Verify a downloaded DMG (what users get)

```bash
spctl -a -t open --context context:primary-signature -v OpenWhisperer-1.5.0.dmg   # → accepted, Notarized Developer ID
xcrun stapler validate OpenWhisperer-1.5.0.dmg                                     # → The validate action worked!
```
A notarized + stapled DMG installs with **no `xattr -cr` / Gatekeeper bypass** — that step (still in
the README) is only for the unsigned/self-signed dev builds.

## First-run permissions (tell users)

On first launch macOS prompts for **Microphone**, **Accessibility**, and **Speech Recognition**.
Note: switching the signing identity (e.g. dev self-signed → Developer ID) changes the code
signature, so macOS **drops prior Accessibility + Microphone grants** — users re-grant once after the
first notarized install. This is expected, not a regression.

## Local dev (no Apple account)

For day-to-day local builds, use a **stable self-signed cert** so TCC grants persist across rebuilds:
```bash
OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh
```
Plain `./build-dmg.sh` (ad-hoc `-`) also works but the cdhash changes each build, so macOS drops the
Accessibility/Microphone grants every rebuild — fine for a one-off test, annoying for iteration.
