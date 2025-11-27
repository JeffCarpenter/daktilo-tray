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
- The default behavior for fresh installs is sourced from `dist-workspace.toml` under `[workspace.metadata.dist.autostart]`. This keeps the runtime and cargo-dist release metadata in sync—flip `default_enabled` there if you want installers to opt users in or out by default, then rebuild.

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
- **Dev/test certificates without a paid CA**: `scripts/provision-dev-cert.ps1` mints a short-lived self-signed code-signing certificate via `New-SelfSignedCertificate`, exports it to a temporary PFX, and reuses `prepare-codesign-secrets.ps1` so GitHub secrets + `.codesign.env` stay in sync. Example:
  ```powershell
  pwsh scripts/provision-dev-cert.ps1 `
    -SubjectName "CN=Daktilo Tray Dev Signing" `
    -PfxPassword "devonly" `
    -Repo yourorg/daktilo-tray
  ```
  Windows will not trust self-signed signatures by default—use this flow for local smoke tests while you work with a publicly trusted CA for release builds. Pass `-SkipGitHubSecrets` if you only want the local `.codesign.env` updated.

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
