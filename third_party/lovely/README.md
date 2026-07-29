# Lovely Injector (bundled)

`version.dll` is the [Lovely Injector](https://github.com/ethangreen-dev/lovely-injector),
**v0.9.0**, Windows x64 build (copied from the Blindfold project's vendored
copy, itself `lovely-x86_64-pc-windows-msvc.zip` from the upstream release).
MIT licensed by its authors.

`scripts/deploy.ps1` copies this file next to `Moonring.exe`; when the game
launches, Windows loads Lovely in place of `version.dll`, and Lovely applies
the patches in `src/lovely.toml` to the game's Lua as it loads.

Mods are loaded from `%APPDATA%\Moonring\Mods` (the LÖVE save directory of the
fused exe + `Mods`).
