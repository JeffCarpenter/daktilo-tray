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
- Releases are built with `cargo-dist`'s MSI pipeline and a follow-up PowerShell script (`scripts/sign-windows.ps1`) that runs `signtool.exe` over every `.exe` and `.msi` artifact. Add these GitHub Actions secrets so CI can import your certificate: `WINDOWS_CODESIGN_PFX` (base64-encoded PFX blob) and `WINDOWS_CODESIGN_PASSWORD` (the PFX password). The workflow skips signing automatically if either secret is absent, which makes unsigned PR builds trivial.
- Use `scripts/prepare-codesign-secrets.ps1 -PfxPath path/to/authenticode.pfx -PfxPassword 'supersecret' -Repo owner/repo` to base64-encode your certificate, push both secrets via `gh secret set`, and drop a local `.codesign.env` file for manual runs. This script expects the [GitHub CLI](https://cli.github.com/) to be installed and authenticated.
- To test locally, install the Windows SDK (for `signtool`) and WiX, export your codesigning certificate to `authenticode.pfx`, and convert it into base64 with `certutil -encode authenticode.pfx authenticode.pfx.b64`. Feed those values to the script manually (`$env:WINDOWS_CODESIGN_PFX = Get-Content authenticode.pfx.b64 -Raw; $env:WINDOWS_CODESIGN_PASSWORD = '...'; pwsh scripts/sign-windows.ps1 -ArtifactsDir target/distrib -BinaryDir target/dist -PfxBase64 $env:WINDOWS_CODESIGN_PFX -PfxPassword $env:WINDOWS_CODESIGN_PASSWORD`) right after running `dist build --installer msi`.

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
