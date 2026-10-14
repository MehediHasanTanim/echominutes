# EM-002 — Signing identity & TCC persistence

**Why this matters:** macOS privacy permissions (Microphone, System Audio Recording, Screen Recording) are stored by TCC against the app's **bundle ID + code-signing designated requirement**. If the app is ad-hoc signed or the identity changes, every rebuild looks like a *new app* and macOS asks for permissions again (or silently denies). EchoMinutes is rebuilt hundreds of times during development, so a stable identity is required from day one.

## 1. Create / confirm the Apple Development certificate

1. Xcode ▸ **Settings ▸ Accounts** → add your Apple ID if missing.
2. Select the team → **Manage Certificates…** → if there is no *Apple Development* certificate, click **+ ▸ Apple Development**.
   - A free Apple ID ("Personal Team") is enough for local development.
   - A paid Developer Program membership is only needed later for a *Developer ID Application* certificate (notarized builds).
3. Run the check (from the repo root, in Terminal):

```bash
scripts/check-signing.sh --write-local
```

This verifies macOS ≥ 14.4, Xcode, the Apple Development identity, prints the **Team ID**, certificate expiry, and writes `Config/Signing.local.xcconfig` (git-ignored) with your `DEVELOPMENT_TEAM`. `Config/Signing.xcconfig` includes it automatically and will be used by the Xcode project in EM-020.

## 2. Confirm TCC prompts persist across rebuilds

```bash
spikes/TCCProbe/run-tcc-test.sh            # uses "Apple Development"
```

What happens:
1. Resets microphone permission for `com.tanimkabir.echominutes.tccprobe`.
2. **Run 1** builds + signs a tiny probe app and launches it → macOS shows the microphone prompt → click **Allow**.
3. **Run 2** rebuilds (binary changes) with the same identity and launches → **no prompt** expected.
4. Prints `RESULT: ✔ PASS` if run 2 reports `before=authorized prompted=no`.

Optional contrast test (shows the problem we're avoiding):

```bash
spikes/TCCProbe/run-tcc-test.sh -          # ad-hoc signing — expected to prompt again / FAIL
```

> If several Apple Development identities exist, pass the SHA-1 from step 1: `run-tcc-test.sh <SHA1>`.
> System Audio Recording permission (process taps) follows the same rule; it is verified in EM-005.

## 3. Results

| Item | Value |
|---|---|
| Date checked | 2026-10-14 |
| macOS / Xcode version | macOS 26.6.2 (arm64) / Xcode 27.0 (27A266a), Swift 6.4 |
| Identity (name) | Apple Development: tanim.cse.buet@gmail.com (Q3DB7G3T8G) |
| Identity SHA-1 | 49FC281F2646A6A997277CD6ECDBE5FD9B945A3D |
| Team ID | G26QS5R4FS (Personal Team) |
| Certificate expiry | 2027-10-14 |
| Developer ID Application | none (not needed for personal use) |
| TCC test (Apple Development) | ✔ PASS — run 1 prompted & granted; run 2 (rebuilt binary) `before=authorized prompted=no` |
| Designated requirement | `identifier "com.tanimkabir.echominutes.tccprobe" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: tanim.cse.buet@gmail.com (Q3DB7G3T8G)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */` |

### Troubleshooting log

- **"0 valid identities found" although Xcode showed the certificate** — the Apple WWDR G3 intermediate certificate was missing, so the identity wasn't trusted. Fixed with:
  ```bash
  curl -fsSLO https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
  security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db
  ```
  `scripts/check-signing.sh` now lists invalid identities and prints this fix.

## 4. Rules going forward

- Never change the bundle ID prefix `com.tanimkabir.echominutes`.
- Always build with the Apple Development identity (Automatic signing, team from `Signing.local.xcconfig`); never "Sign to Run Locally".
- Renew the certificate before it expires; after renewal, re-run the TCC test (permissions may need re-granting once).
- If permissions get into a bad state: `tccutil reset Microphone com.tanimkabir.echominutes` (and `AudioCapture`, `ScreenCapture`).
