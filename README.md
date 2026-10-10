# Echo Show 5 on Apple Silicon

A working-path guide and starter tools for installing LineageOS on the **first-generation Amazon Echo Show 5 (CHECKERS)** using an Apple Silicon Mac.

One device reached TWRP, successfully installed LineageOS 18.1 v0.7, completed setup and connected to Wi-Fi. This is experimental: repeatability and full hardware functionality remain untested.

## Guided source preview

A native SwiftUI app, shared Swift workflow engine, CLI and local MCP server are included. Run `bash script/build_and_run.sh` with Swift 6/Xcode tools installed. The app provides verified downloads, structured host inspection, managed-VM creation and recovery/backup adapter controls. Guest preparation and live backup integration still need validation. Unlock/wipe/install execution is disabled in this preview.

- [Implementation status](docs/prototype-status.md) and [test evidence](docs/implementation-results.md).
- [AI setup and portable skill](docs/ai-integration.md).
- Build a shareable source preview with `bash script/package-release.sh`.

## Start here

- [Installation walkthrough](docs/install-guide.md): what to connect, click and verify.
- [Guided Mac app proposal](docs/guided-app.md): how we can remove the manual work.
- [Evidence and remaining questions](docs/validation.md): what we know actually worked.
- [Verified download hashes](hashes.json).

Project-authored code and documentation are MIT licensed; upstream tools retain their own licenses.

The tools directory contains guest translation setup, an offline protocol mock and a bounded unlock runner. They are not a complete installer. Run tools in a dedicated Linux guest as described in the guide. No vendor binaries, ROMs, VM accounts or device backups are distributed here. Download vendor artifacts from the linked maintainers.

## Contributing

Start with documentation corrections, offline tests and read-only device checks. Report exact device codename, LK build, host/UTM versions and observed results. Redact serials, addresses and credentials. Never upload raw device backups. A host timeout does not prove an unlock.

This project credits amonet developers k4y0z and R0rt1z2, the amazon-oss ROM maintainers, UTM and Debian. It wraps their work; it does not claim authorship of their exploit or ROM.

Published as an experimental starter kit. VM creation, first USB assignment and partition backups remain manual; the app currently automates preflight checks and verified UTM/ROM downloads. See the walkthrough before using it. No license has been selected yet.
