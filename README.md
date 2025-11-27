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
- Releases are built with `cargo-dist`'s MSI pipeline and the GitHub Actions workflow is wired to call SSL.com's Signing-as-a-Service so Windows sees the binaries as first-party. Add the following GitHub Actions secrets with the credentials SSL.com provides: `SSLDOTCOM_USERNAME`, `SSLDOTCOM_PASSWORD`, `SSLDOTCOM_TOTP_SECRET`, and `SSLDOTCOM_CREDENTIAL_ID`.
- For local signing or dry runs, install the WiX toolset plus Microsoft's `signtool` (part of the Windows SDK), export your PFX certificate, and set the same environment variables before invoking `dist build --installer msi`. The signing service will be skipped automatically if the secrets are missing, so you can still iterate unsigned.

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
