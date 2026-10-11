# Signing and TestFlight checklist (M7)

Everything in this repo builds unsigned in CI (simulator Debug plus a device Release build, `CODE_SIGNING_ALLOWED=NO`). The steps below need an **Apple Developer Program membership** and a Mac with Xcode 26. Mark each box when done.

## 1. Apple Developer account (developer.apple.com)

- [ ] Enroll in the Apple Developer Program, as an individual or an organization. An organization needs a D-U-N-S number, and the seller name shows on the App Store.
- [ ] Certificates, Identifiers & Profiles › Identifiers › App ID `com.hpl.lifestyle`. Change it in `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`, `bundleIdPrefix`) if the prefix is taken.
  - Capabilities: **HealthKit** (Clinical Health Records **off**), **HealthKit Background Delivery** (enabled automatically with HealthKit on recent Xcode; `VERIFY`), **Data Protection: Complete**.
  - Not needed in this version: App Groups, Push Notifications (reminders are local), iCloud, App Attest, Associated Domains.
- [ ] Use automatic signing (simplest): Xcode › target › Signing & Capabilities › Team. Or, for manual signing, create an *Apple Distribution* certificate and an *App Store* provisioning profile.

## 2. Local project setup

```bash
brew install xcodegen
xcodegen generate                       # HeartyPatchLifestyle.xcodeproj (git-ignored)
```

- [ ] Set `DEVELOPMENT_TEAM` in `project.yml`, or pick the team in Xcode (the regenerated project resets it).
- [ ] `MARKETING_VERSION` is `0.7.0`. Increase `CURRENT_PROJECT_VERSION` for **every** upload; App Store Connect rejects duplicate build numbers.
- [x] App icon: `App/Assets.xcassets/AppIcon.appiconset` has a 1024×1024 single-size placeholder (plain heart, no ECG or pulse imagery, which could suggest medical monitoring). [ ] Replace it with a designed icon before App Store submission.
- [ ] Run on a physical iPhone (Debug) once to confirm the HealthKit permission sheet, background delivery and the Keychain.

## 3. App Store Connect record (appstoreconnect.apple.com)

- [ ] My Apps › + › New App: platform iOS, name (see `Metadata/app-store/en-US/name.txt`; **trademark check on "HeartyPatch" / "HP" first**, §12 open decision), primary language English (U.S.), bundle ID `com.hpl.lifestyle`, SKU e.g. `hpl-lifestyle-ios`.
- [ ] Category: **Health & Fitness** (primary), Lifestyle (secondary). Not Medical.
- [ ] Age rating questionnaire: no objectionable content. Answer "Medical/Treatment Information: None" (the app gives general wellness information only); `VERIFY` wording at submission.
- [ ] Privacy Policy URL: `docs/privacy-policy.md` published at a stable public URL (GitHub Pages or a site). **Required for HealthKit apps and for external TestFlight.**
- [ ] Copy from `Metadata/app-store/en-US/` (description, keywords, promotional text, support URL). CI runs `scripts/check_store_copy.py` on these files.

## 4. App Privacy ("nutrition label")

App Store Connect › App Privacy. Apple counts data as "collected" only when it is transmitted off the device. In this build nothing is: no server, no analytics, and the cloud demo runs on device.

- [ ] **Data Not Collected.**
- [ ] Matches `App/PrivacyInfo.xcprivacy` (no tracking, no collected data types; UserDefaults reason `CA92.1`).
- [ ] **Revisit before a real cloud endpoint ships.** Health & Fitness data would then be "collected", "not linked to the user", "not used for tracking", for the purpose "App Functionality". Update the manifest, this label, the privacy policy and the consent copy together.

## 5. Export compliance

- [ ] `ITSAppUsesNonExemptEncryption = NO` is already in Info.plist (`project.yml`). The app only uses Apple's OS-provided encryption (Data Protection, CryptoKit HMAC/SHA-256 for signatures, TLS in the unused HTTPS transport). This qualifies for the exemption; `VERIFY` with the current Apple and BIS guidance.

## 6. Archive and upload

```bash
xcodebuild -project HeartyPatchLifestyle.xcodeproj -scheme HeartyPatchLifestyle -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/HPL.xcarchive archive
xcodebuild -exportArchive -archivePath build/HPL.xcarchive -exportPath build/export \
  -exportOptionsPlist scripts/ExportOptions-appstore.plist   # method app-store-connect, teamID, automatic signing
```

Or in Xcode: Product › Archive › Distribute App › App Store Connect › Upload.

- [ ] Processing finishes (about 5–30 min); answer the export compliance prompt if asked.

## 7. TestFlight

- [ ] Internal testing: add up to 100 App Store Connect users. No review needed. Use this for the first device pass (§ "Device checks" in `docs/m7-release.md`).
- [ ] External testing (M7 exit: **10 testers × 2 weeks**): create a group, then fill in Test Information:
  - beta description and what to test (`Metadata/app-store/en-US/release_notes.txt`)
  - feedback email
  - privacy policy URL
  - **Beta App Review notes** (`Metadata/app-store/en-US/review_notes.txt`): no sign-in is needed; explain how to see the labeled example data without Health.
- [ ] Submit the build for Beta App Review (first external build only; usually under 48 h).
- [ ] Short review by a health-tech/privacy lawyer **before** external testing (§13).
- [ ] Track P0 bugs. Exit when there are 0 P0s after 2 weeks.

## 8. Before App Store submission (post-M7)

- [ ] Screenshots: 6.9" and 6.5" iPhone, wellness framing only (no "detect", "diagnose" or risk language; reuse the CI copy check wording).
- [ ] Re-verify guidelines 1.4.1, 5.1.1 and 5.1.3 text at submission time.
- [ ] Decide on the backup exclusion default (§12; today the OS default is to include app data in backups, as the privacy copy says).
