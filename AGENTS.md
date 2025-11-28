# Repository Guidelines

## Project Structure & Module Organization
- Primary logic lives in `src/main.rs`; it wires up the tray icon, listens for key events, and forwards them to `daktilo_lib`
- Static tray art is inside `assets/typewritter_icon_enabled.png` and `assets/typewritter_icon_disabled.png`, which `build.rs` re-exports via `include_bytes!`
- `Cargo.toml` and `build.rs` define dependencies (e.g., `rodio`, `tao`, `tray_icon`) and the icon embedding step, while `target/` holds build outputs and should be ignored in commits

## Build, Test, and Development Commands
- `cargo build --release` compiles the tray executable with optimizations and runs `build.rs` to bundle assets
- `cargo run --release` starts the tray app locally; it mimics the installed binary and is preferred during rapid iteration
- `cargo fmt` keeps Rust code formatted to the default toolchain style; run it before committing
- `cargo clippy --all-targets --all-features` is available for catching lints early, especially before pushing

## Coding Style & Naming Conventions
- Follow Rust conventions: 4-space indentation, `snake_case` for functions/variables, `PascalCase` for structs/enums, and UPPER_SNAKE_CASE for constants like the embedded icon buffers
- Rely on `cargo fmt` and the standard formatter options; avoid mixing tabs
- Keep new modules focused; prefer descriptive, short identifiers that match existing names (`State`, `EventKind`, `load_icon`)

## Testing Guidelines
- Tests live beside the code they cover (`#[cfg(test)]` modules in `src/`) or under a `tests/` directory; there are no dedicated suites yet, so add them as features evolve
- Use `cargo test` to run the full suite; for targeted runs, append `--lib` or `--test <name>`
- Name tests to describe expected behavior (e.g., `fn state_persists_after_cache_write()`)

## Commit & Pull Request Guidelines
- History uses short, imperative commits (`cargo update`, `Update README`). Keep messages like `Fix tray icon refresh` or `Add device selection handling`
- PR descriptions should explain what changed, list manual verification steps (`cargo run --release`, `cargo fmt`), and link relevant issues or roadmap items
- Include screenshots or notes when UI/device handling logic changes and mention whether the cache state file format shifted

## Assets & Configuration Tips
- New assets must be added to `assets/` and referenced in `main.rs` via `include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/..."))`
- Runtime state serializes to the cache file created via `directories::BaseDirs`; update `State` serialization whenever fields change

## Additional References
- See `HACKING.org` for environment bootstrapping, release automation, and script-level workflows.***
- When reading repo files via `python -c`/PowerShell, pass `encoding='utf-8'` (or `-Encoding UTF8`) to avoid the recurring Windows `UnicodeDecodeError: 'charmap'` failures.
