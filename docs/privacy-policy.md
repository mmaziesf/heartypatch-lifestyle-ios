# HP Lifestyle privacy policy (draft)

*Draft for TestFlight, effective on first external build. Not legal advice. Have it reviewed (architecture §13) before external testing, and keep it in step with `PrivacyCopy`, `App/PrivacyInfo.xcprivacy` and the App Privacy answers in `docs/testflight-checklist.md`.*

HP Lifestyle ("the app") is a personal wellness app for iPhone. It is not a medical device and does not provide medical advice.

## Summary

- Your data stays on your iPhone. The app has no account and no server, and the developer receives none of your data.
- No advertising, no analytics or tracking SDKs, and no selling or sharing of data.
- You can export everything or delete everything at any time in Settings › Privacy & your data.

## What the app stores, and where

All of the following stays on your iPhone, in the app's container, protected with iOS Data Protection ("Complete": encrypted and unreadable while the phone is locked):

| Data | Source | Kept as |
|---|---|---|
| Sleep, heart rate, HRV, resting heart rate, steps, active energy, exercise minutes, workouts, body measurements | Apple Health, read-only, with your permission | Per-day totals only (no raw samples), for the last 90 days onward |
| Lab results | Reports you import (PDF or photo) | The original file plus the values you confirmed, as printed on the report |
| Meals | Entered by you, or signed files from a glasses companion app you paired | Time, label, simple tags, item names and calorie estimates you confirmed. Photos are not imported. |
| Notes and experiments | Generated on your iPhone from the above | Text, the values each note cites, your feedback and check-ins |
| Pairing keys for companion apps | Created when you pair | iOS Keychain, this device only |
| Consents and settings | Your choices | On device |
| Cloud analysis history | Only if you turn cloud analysis on | The exact payload of each job and its result |

The app never writes to Apple Health and never uses Health data for advertising or marketing. Health data is not stored in iCloud by the app.

**Backups:** if you back up your iPhone to iCloud or a computer, iOS includes the app's data in that backup. Encrypted backups protect it.

## What leaves your iPhone

- **Nothing**, in the current version.
- **Cloud analysis** is off by default. If you turn it on, each analysis is a separate job: you preview the exact de-identified, coarsened numbers and approve them before anything runs. In the current version the analysis runs on your iPhone (no server). If a remote service is added later, this policy, the in-app consent and the App Store privacy details will be updated first, and you will be asked to consent again. Even coarsened data could potentially be linked back to you by someone with other data about you; the consent screen says so.
- **Files you export** (Settings › Export all data, Insights › Export JSON) go wherever you choose to save or share them.
- **Crash reports:** only Apple's built-in reporting, if you have chosen to share analytics with developers in iOS Settings. These don't include your health data.

## Your choices

- **Apple Health access:** iOS Settings › Privacy & Security › Health › HP Lifestyle.
- **Notifications:** one optional daily reminder, which never shows your data on the lock screen. Turn it off in Settings › Notifications or in iOS Settings.
- **Consents:** Settings › Consents lists each consent with its version and dates. Cloud analysis and glasses meals can be turned off in their sections.
- **Export:** Settings › Privacy & your data › Export all data (JSON).
- **Delete:** Settings › Privacy & your data › Delete all data removes everything listed above from the app, including Keychain items, report files, settings and scheduled reminders, and then checks that nothing is left. Data in Apple Health is not affected. Deleting the app also removes its data.

## Children

The app is not directed to children under 13.

## Changes and contact

Material changes will be announced in the app before they take effect. Contact: `TODO: support email` (also listed on the App Store page).
