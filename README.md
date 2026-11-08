# DeepSeek Usage Tracker

A native macOS menu bar tracker for **DeepSeek balance** and **today's usage**: two compact numbers in the menu bar, a detailed menu, and a small settings window.

Maintained by [okric](https://github.com/okric).

![Menu bar item](docs/statusbar.png)

![Settings window](docs/settings.png)

## What it shows

- **Available balance** — the primary wallet plus any other positive currency balances (for example a CNY bonus on a USD account).
- **Today** — spend in the currency that was actually charged today, plus tokens, request count, and cache-hit rate.
- **Last 30 days** — token total, with a 7-day token/request breakdown. Token counts are currency-neutral; spend is intentionally shown only for *today* because an account can have cost buckets in more than one currency.
- **Low-balance and session states** — green/normal, orange/low, red/unavailable or rejected credential, with the last good values kept and marked stale.
- Refresh every 1, 5, 15, or 30 minutes; wake-from-sleep refresh; manual refresh.
- Launch at login, auto-enabled on first launch from `/Applications`, with an on/off toggle under **Settings → Startup**.

## First run

1. Make sure [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) is installed and signed in — this tracker has exactly one identity source: the Harness credential file at `~/.dsh/.credentials.yaml`.
2. Build and launch the app. It lives in the menu bar (no Dock icon). If the Harness login is missing, the settings window explains it on first launch.
3. Nothing else to configure: the login is read live at every refresh; there is no copy, no browser sign-in, and no key entry in this app.

If `~/.dsh/.credentials.yaml` still contains an API key (`refs.DEEPSEEK_API_KEY`), the app prefers the official `api.deepseek.com/user/balance` endpoint for the balance row; otherwise it uses the platform account summary with the account token.

## How the data is obtained

| Data | Endpoint | Credential |
|---|---|---|
| Balance (with API key) | `GET https://api.deepseek.com/user/balance` | Harness API key (`Bearer`) |
| Platform balance | `GET https://platform.deepseek.com/api/v0/users/get_user_summary` | Harness account token (`x-dsh-auth-token`) |
| Today / daily usage | `GET .../api/v0/usage/by_api_key/amount?start=&end=&tz=` and `.../cost` | Harness account token |
| Monthly fallback | `GET .../api/v0/usage/amount?month=&year=` and `.../cost` | Harness account token |

DeepSeek does not document a public usage API. The usage endpoints are the private dashboard endpoints. They can change or rate-limit without notice; the platform summary keeps the balance row working if they do.

**Currency detail:** DeepSeek can return cost data in more than one currency. For example, a USD wallet may hold older spend while today's usage is charged against a CNY bonus. The parser therefore chooses the cost block with spend *today* for the “Today” number, rather than blindly preferring USD. The 30-day row shows only tokens to avoid presenting an invalid cross-currency total.

## Security

- The Harness login is **never stored**: it is read live from `~/.dsh/.credentials.yaml` (owner-readable) only at request time; no Keychain items exist at all.
- No `.env`, plist, or UserDefaults secrets, and no telemetry. Account name is the only cached value.
- The Harness file is never watched, uploaded, or modified; the app only reads the documented `deepseek-account-platform/default` grant and `refs.DEEPSEEK_API_KEY`.
- Authenticated requests disable redirects; a revoked session surfaces as a rejected-request warning with a "re-sign in from Harness" action.
- For distribution the app is signed with a Developer ID Application certificate and Apple-notarized (see `Scripts/notarize.sh`).

## Build and test

Requirements: macOS 14+ and Xcode.

Open `DeepseekUsageTracker.xcodeproj` in Xcode and use **Product → Run** / **Test**, or build and test from the command line:

```bash
xcodebuild -project DeepseekUsageTracker.xcodeproj \
  -scheme DeepseekUsageTracker -configuration Debug \
  -derivedDataPath build build

xcodebuild -project DeepseekUsageTracker.xcodeproj \
  -scheme DeepseekUsageTracker -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' test
```

The checked-in `DeepseekUsageTracker.xcodeproj` is the source of truth. Add or remove files through Xcode’s project navigator so the project updates itself; no project generator is required.

The project is configured for automatic signing. For your own build, select your Team under **Signing & Capabilities**; the bundle identifier is `com.deepseekusage.tracker`. The 15 tests cover balance/usage parsing, multi-currency cost selection, date windows, PKCE/URL validation, the loopback callback server, the Harness YAML parser, and the Keychain round-trip.

Release build:

```bash
xcodebuild -project DeepseekUsageTracker.xcodeproj \
  -scheme DeepseekUsageTracker -configuration Release \
  -derivedDataPath build build
```

## Updates

The app updates itself with [Sparkle 2](https://sparkle-project.org). Each
release publishes an `appcast.xml` beside the DMG; the app reads `SUFeedURL`
from `Info.plist` (`…/releases/latest/download/appcast.xml`), verifies the
EdDSA signature against `SUPublicEDKey`, and installs silently. Checks run
daily, and "Check for Updates…" lives in the menu.

- The signing key is a single Ed25519 key for all okric apps, stored in the
  login keychain under account `okric`. Restore it with
  `generate_keys --account okric -f <backup-file>`; the exported key belongs
  in a password manager. Losing it means existing installs can never be
  updated again.
- `Scripts/notarize.sh` bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
  (Sparkle compares the build number), re-signs the embedded Sparkle framework
  inside-out, and generates + uploads `appcast.xml`.
- Releases before the first Sparkle build have no updater; install that one
  manually from the DMG.

## Layout

```
Sources/
  App/        App entry point, AppModel, menu bar controller
  Core/       API client, models, Harness credential importer
  UI/         Status item drawing, settings window (SwiftUI)
Tests/        Parser, date, endpoint, Harness credential tests
docs/         README screenshots (sample values, not account data)
Scripts/      notarize.sh (sign → notarize → staple → publish DMG)
```

## Notes

- The app is independent and not affiliated with DeepSeek.
- The Harness token is tied to the account session; if it is revoked, re-sign in from DeepSeek Harness and refresh.
- The tracker follows the Harness login for its whole lifetime; there is no separate sign-in path.

## References

- [DeepSeek API — Get User Balance](https://api-docs.deepseek.com/api/get-user-balance/)
- [CodexBar DeepSeek provider notes](https://github.com/steipete/codexbar/blob/main/docs/deepseek.md)
- [dsh-deepseek-usage](https://github.com/AzureHalcyon/dsh-deepseek-usage)
- [DeepSeek Harness account-platform package](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/credentials/deepseek-account-platform/README.md)

Project author: [okric](https://github.com/okric)

> **AI usage note:** The code in this project was "vibe coded" with [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) and **DeepSeek V4.1 Flash**.
