# Introduction
[daktilo](https://github.com/orhun/daktilo) is a small command-line program that plays typewriter sounds every time you press a key.

**daktilo-tray** brings **daktilo** to the tray. It was tested on Windows, but it should also work on Linux and MacOs.

![Screenshot 2024-04-21 131817](https://github.com/ndtoan96/daktilo-tray/assets/33489972/80de0286-30b2-4146-ad9c-c5ce598376e4)

# Installation
Pre-built binaries are provided at [release](https://github.com/ndtoan96/daktilo-tray/releases).

## Cargo
```bash
cargo install daktilo-tray
```

## Launch at Login
- Toggle the new **Launch Daktilo Tray at login** checkbox from the tray menu to register or remove the app from the OS startup list. The preference is cached next to the rest of the tray state so it survives restarts.
- The default behavior for fresh installs is sourced from `dist-workspace.toml` under `[workspace.metadata.dist.autostart]`. This keeps the runtime and cargo-dist release metadata in sync-flip `default_enabled` there if you want installers to opt users in or out by default, then rebuild.
- Automation and smoke tests can set `DAKTILO_AUTOSTART_ONLY=1` before launching the installed binary; the app will apply the metadata default to the registry, verify it, and exit immediately (no tray/threads are spawned). `scripts/test-installer.ps1` relies on this path to validate MSIs inside CI.

## Code Signing
- Releases are built with `cargo-dist`'s MSI pipeline and a follow-up PowerShell script (`scripts/sign-windows.ps1`) that runs `signtool.exe` over every `.exe` and `.msi` artifact. Add these GitHub Actions secrets so CI can import your certificate: `WINDOWS_CODESIGN_PFX` (base64-encoded PFX blob) and `WINDOWS_CODESIGN_PASSWORD` (the PFX password). The workflow skips signing automatically if either secret is absent, which keeps unsigned PR builds trivial.
- **One-command release wizard** (PowerShell, elevated). This script exports your Authenticode cert, uploads GitHub secrets, runs `dist build`, signs everything, and optionally tags the repo. Copy/paste the command, tweak the arguments, and let it cook:
  ```powershell
  pwsh scripts/release-windows.ps1 `
    -SubjectName "CN=Your Company" `
    -StoreLocation LocalMachine `
    -PfxPassword 'supersecret' `
    -Repo yourorg/daktilo-tray `
    -Tag v0.1.1
  ```
  Switch to `-Thumbprint 'ABCD1234...'` if you want an exact match instead of a subject search, or pass `-SkipSecrets` on subsequent runs to reuse the `.codesign.env` snapshot it drops alongside the repo.
- **Prereqs**: install [GitHub CLI](https://cli.github.com/), `cargo-dist` (`cargo install cargo-dist`), WiX (for MSI generation), and the Windows 10+ SDK (so `signtool.exe` exists). The script will error out with actionable messages if any of them are missing.
- **Manual variants**:
  - `scripts/bootstrap-codesign.ps1` (export + secret publication only) and `scripts/prepare-codesign-secrets.ps1` (already have a `.pfx` file) remain available if you need granular control.
  - `scripts/sign-windows.ps1` can be called directly with `-PfxBase64`/`-PfxPassword` to sign arbitrary artifacts immediately after `dist build --installer msi`.
- **Channel-aware defaults**: `[workspace.metadata.dist.codesign.channels.*]` in `dist-workspace.toml` describe certificate stores, selectors, env files, and now GitHub routing fields per track (`dev`, `stable`, ...). Pass `-Channel` to `scripts/release-windows.ps1` so it auto-selects the right cert, targets the right repo/environment for `gh secret set`, and resolves `signtool.exe` from the Windows SDK even when it is not on `PATH`.
- **Dev/test certificates without a paid CA**: `scripts/provision-dev-cert.ps1` mints a short-lived self-signed code-signing certificate via `New-SelfSignedCertificate`, exports it to a temporary PFX, and reuses `prepare-codesign-secrets.ps1` so GitHub secrets + `.codesign.env` stay in sync. Example:
  ```powershell
  pwsh scripts/provision-dev-cert.ps1 `
    -SubjectName "CN=Daktilo Tray Dev Signing" `
    -PfxPassword "devonly" `
    -Repo yourorg/daktilo-tray
  ```
  Windows will not trust self-signed signatures by default-use this flow for local smoke tests while you work with a publicly trusted CA for release builds. Pass `-SkipGitHubSecrets` if you only want the local `.codesign.env` updated.

## Installer Smoke Tests
- `scripts/test-installer.ps1 -ArtifactsDir <path>` installs the freshly built MSI, launches the installed tray binary with `DAKTILO_AUTOSTART_ONLY=1`, checks that the HKCU `Run` entry matches `[workspace.metadata.dist.autostart.default_enabled]`, runs `signtool verify /pa /v` on the MSI, uninstalls, and stashes logs under `target/smoke-tests/`.
- `.github/workflows/release.yml` now includes an `installer-smoke` job that downloads the Windows artifacts, runs the helper, uploads the logs, and blocks release publishing if the MSI fails to install, set autostart, or verify its signature.

# Supply-chain Guardrails
- CI installs `cargo-pants` and runs `scripts/run-cargo-pants.ps1`, which captures the CLI output, inspects every `CVSS Score`, and only fails the Windows release job when the maximum score meets the threshold published in `dist-workspace.toml` (`[workspace.metadata.dist.supply_chain]`).
- Declare `[workspace.metadata.dist.supply_chain.channels.<name>]` to specialize thresholds and `--dev` inclusion per channel. The workflow passes `dev` for pull requests (laxer threshold, include dev dependencies) and `stable` for signed tags so your hotfix builds stay strict without disrupting day-to-day iteration.
- To exercise the same gate locally: `pwsh scripts/run-cargo-pants.ps1 -SeverityThreshold 7.5`. Add `-IncludeDevDependencies` to mirror the `--dev` behavior when you need to scan the full dependency graph.
- Maintain `.pants-ignore` with the OSS Index vulnerability IDs you have accepted so the helper (and CI) stays green while you work on patches.

# Coverage
- Run `pwsh scripts/run-coverage.ps1 -HtmlReport -GenerateJUnit` to reset instrumentation, execute the workspace, emit `target/coverage/lcov.info`, build the HTML dashboard (`target/coverage/html`), and capture the JSON/JUnit/exit-code bundle under `target/coverage` and `target/test-results`. The helper installs `cargo-llvm-cov`/`cargo2junit` when missing, fails fast if artifacts are absent, and leaves behind the Markdown summary consumed by CI.
- `.github/workflows/coverage.yml` runs the same helper on `windows-latest`, then feeds `target/test-results/junit.xml` into `dorny/test-reporter@v2` so pull requests get a structured test check alongside the uploaded `coverage-<run-id>` artifact (LCOV, HTML, JSON, JUnit).
- The helper also rewrites `target/coverage/summary.md` and appends it to `$GITHUB_STEP_SUMMARY`, so reviewers see coverage/test deltas inline without digging through logs; GitHub caps each summary at 1 MiB, which the script respects by emitting a terse table.

# ACME Bootstrap / Let's Encrypt + Caddy
- `scripts/request-acme-pfx.ps1` automates spinning up `caddy run`, acquiring a Let's Encrypt (or staging) TLS certificate for `sign.yourdomain.com`, and writing a password-protected PFX you can stash as part of your release secrets. This is ideal for staging and for proving domain control to a commercial Authenticode CA.
- Example:
  ```powershell
  pwsh scripts/request-acme-pfx.ps1 `
    -Domains @("sign.example.com","www.sign.example.com") `
    -Email ops@example.com `
    -OutputPfx .\certs\lets-encrypt-staging.pfx `
    -PfxPassword 'change-me'
  ```
- If you built Caddy with the Cloudflare DNS module, append `-DnsProvider cloudflare -CloudflareApiToken $env:CLOUDFLARE_API_TOKEN` to satisfy DNS-01 via Cloudflare instead of HTTP-01. Remember Let's Encrypt certificates cover TLS-not code signing-so feed the resulting PFX into your higher-trust workflow or keep using `scripts/provision-dev-cert.ps1` for local smoke tests.
- Want an automated, auditable run? Trigger the **Request ACME PFX** workflow in GitHub (manual dispatch). It installs Caddy on a Windows runner, calls `scripts/request-acme-pfx.ps1` with your domains/email, optionally feeds Cloudflare DNS tokens, and uploads both the PFX and pre-formatted `.env` snapshot as a one-click artifact for operators.
- That workflow now accepts an `environment_name` input; the job binds to that GitHub environment (so approvals apply) and immediately runs `gh secret set --env <name>` for `WINDOWS_CODESIGN_PFX`/`WINDOWS_CODESIGN_PASSWORD`, keeping the release wizard in sync without copying secrets by hand.

# Roadmap
- [X] Change preset in realtime
- [X] Change output device in realtime
- [X] Enable/disable app
- [X] Caching app state
- [X] Launch at login toggle
- [ ] Configure custom presets
- [ ] Auto detect new audio devices
- [ ] Global shortcut
- [ ] Support other installation methods (nix, winget,...)





