# Native macOS Telegram diagnostic — no login

This small, public-source probe opens the signed official Telegram macOS application on a fresh GitHub-hosted macOS 26 runner and captures the actual desktop/window pixels. It creates no custom UI, HTML reconstruction, replacement messages or composited screenshots. It has not yet been executed or compiled on macOS; successful capture is not claimed.

## Scope

The only expected application content is an unauthenticated welcome/login screen. The probe never enters a phone number, scans a QR code, imports a session, authenticates a Telegram account or sends messages. It is not a bot-chat demonstration. Never put credentials, session files, personal data or authenticated screenshots in this repository. The fresh runner is discarded after the job.

The application is downloaded from `https://telegram.org/dl/macos`, currently redirecting to `https://osx.telegram.org/updates/Telegram.dmg`. DMG integrity, Gatekeeper, bundle `ru.keepcoder.Telegram`, signing team `6N38VWS5BX`, GUI console user, WindowServer and the actual application window are checked. No application-signature or macOS privacy protection is disabled. Screen-capture preflight is diagnostic; inspect the resulting PNG before accepting it.

## Manual, public, standard runner only

The workflow can be dispatched only manually and its job runs only when the repository is public and the initiating actor is its owner. It uses standard `macos-26`, a ten-minute limit and `contents: read`; checkout credentials are not persisted. There is no upload-artifact, cache, larger runner, custom image, external image upload or server. No account secrets are required. Publication and execution are separate owner decisions; this prepared source does not itself publish or dispatch anything.

According to [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions), standard hosted runners in public repositories are free independently of included compute; larger runners are billed. The same page states that job logs and summaries do not count toward artifact storage. This workflow transmits bounded diagnostics in normal job logs and creates no Actions artifacts or caches. These conditions are the basis for the zero-charge design, not a statement that a job has run or a bill has been checked.

## Diagnostic log format

Only these five files can be emitted: `macos-version.txt`, `window-probe.json`, `capture-metadata.json`, `native-desktop.png`, `native-telegram-window.png`. The PNG limit is 6 MiB each, JSON 64 KiB each, version text 4 KiB and combined input 14 MiB. Files must be regular, without symlinks; unknown paths are never opened. Exact metadata schemas require successful native capture, no login attempt, zero messages, no reconstruction/compositing and unchanged image hashes/dimensions. All five files are validated before any payload is printed.

Normal log lines contain this protocol (JSON headers are single lines):

```text
NATIVE_DIAGNOSTICS_V1_BEGIN
NATIVE_DIAGNOSTICS_FILE_BEGIN {"file":"...","bytes":123,"sha256":"...","encoding":"base64"}
BASE64_DATA_LINES_AT_MOST_120_CHARACTERS
NATIVE_DIAGNOSTICS_FILE_END {"file":"..."}
...exactly five files...
NATIVE_DIAGNOSTICS_V1_END {"files":5,"total_bytes":12345}
```

After the run has completed, a parser may remove GitHub's timestamp prefix, require exactly one complete block, accept only the five fixed names, verify each byte length and SHA-256 and apply the same size limits before writing anything. Missing/truncated blocks are failures; never substitute a reconstruction. The payload is publicly visible in job logs, including any unauthenticated application QR screen. Do not use this probe for a logged-in session. No arbitrary process termination is attempted; the job ends and its ephemeral runner is discarded.

`capture.sh` and `window_probe.swift` are unchanged copies of the reviewed native-only tools. The helper only discovers/activates the official application; it renders no UI. Windows/Linux execution is refused. Local validation covers synthetic diagnostics and syntax only; native Swift compilation, TCC behavior and the actual screenshot require the eventual permitted macOS run. The MIT license covers this probe's source, not the separately downloaded Telegram application or its trademarks.
