# Install LineageOS on Echo Show 5 using an Apple Silicon Mac

A working-path guide and starter tools for installing LineageOS on the **first-generation Amazon Echo Show 5 (CHECKERS)** using an Apple Silicon Mac.

One device reached TWRP, successfully installed LineageOS 18.1 v0.7, completed setup and connected to Wi-Fi. This is experimental: repeatability and full hardware functionality remain untested.

## Start here: choose your next action

**Want to install LineageOS on your Echo?** Start with the [manual installation walkthrough](docs/install-guide.md). That is the path used in our successful installation. The app preview cannot complete an installation yet.

**Want to try the app or help finish it?** Follow the steps below. The [next implementation steps](docs/next-steps.md) explain exactly what to build and verify afterward.

### Try the source preview in order

1. **Get the project.** Open Terminal and run:

   ```bash
   git clone https://github.com/tn9design/echo-show-5-apple-silicon.git
   cd echo-show-5-apple-silicon
   ```

2. **Check your build tools.** Run `swift --version`. You need Swift 6 or later from Xcode or its Command Line Tools. If Swift is missing, run `xcode-select --install`, finish Apple's installer, then check again.
3. **Open the app.** Run `bash script/build_and_run.sh --verify`. If EchoGuide is already running, finish any operation and quit it first; the script will not force-close it.
4. **Check your Mac.** Select **Check your Mac**, then click **Inspect this Mac and USB**. Read the host result and USB candidates. USB visibility does not establish a supported Echo model. The installation backend requires Apple Silicon and macOS 27 or later; fresh-host validation remains outstanding.
5. **Prepare the downloads.** Select **Prepare downloads**, choose a folder, and let the app download and verify UTM, the pinned Debian installer, and the ROM. Wait for the verified-download result. This does not install or execute the downloads.
6. **Review the remaining setup.** Open **Linux workspace** and read the guided input-device, translation and USB-assignment steps. VM creation and guest bootstrap are pilot integrations, not a validated automatic setup. Follow the manual walkthrough if you intend to install today.
7. **Keep device changes separate.** Recovery verification and backup controls are intended for compatible TWRP and still need live validation. Unlock, wipe and installation execution are disabled in the app, CLI and MCP preview. Do not interpret a pending approval as an operation that ran.
8. **Share useful feedback.** Open **Troubleshooting**, create a redacted diagnostic preview, review it, and save it. Include the step where you stopped and what you expected. Never upload raw backups or private session details.

To add an assistant after the app is set up, follow [AI setup and the portable skill](docs/ai-integration.md). For current limits and test results, read [implementation status](docs/prototype-status.md) and [test evidence](docs/implementation-results.md).

## Ask your AI to help

Share this repository URL with your assistant and paste:

> Help me install LineageOS on my Echo Show 5 using this repository. Read `README.md`, `docs/install-guide.md`, `docs/prototype-status.md`, and `skills/echo-guide/SKILL.md` first. Verify my exact Echo model/bootloader and computer compatibility before proceeding. The guided app is unfinished; do not assume guest bootstrap or installation is validated. Follow the documented manual path if appropriate, keep backups local and verify them, and ask before destructive actions. Stop on unknown results rather than treating a timeout as success.

Reading the skill provides guidance; it does not automatically install the local MCP server or grant device access. Use [AI integration setup](docs/ai-integration.md) for supported local tooling. The assistant must be able to read the repository files; if it cannot, provide those files before proceeding. No AI subscription is required to use the guide.

## Installation checkpoints

Follow the [detailed walkthrough](docs/install-guide.md) in this order. Advance only after the current checkpoint is established:

| Step | Action | Result needed before continuing |
|---|---|---|
| 1 | Prepare the Mac, files and isolated Linux VM | Pinned files verified; translation and offline client test pass |
| 2 | Connect wall power and the Micro-USB data cable; assign USB | Linux sees the selected Echo |
| 3 | Check device identity | CHECKERS and the exact supported LK build match |
| 4 | Decide whether to run the reviewed experimental unlock | Compatible TWRP is independently verified; timeout alone is insufficient |
| 5 | Capture private backups | Required images have matching sizes and hashes |
| 6 | Stage and verify the ROM, then approve erasure | Backups and device-side ROM are verified |
| 7 | Wipe data/system/cache, install, save the log, then reboot | Current installer success is verified before reboot |
| 8 | Complete Android setup | Home screen reached; hardware checks recorded separately |

Project-authored code and documentation are MIT licensed; upstream tools retain their own licenses.

The tools directory contains guest translation setup, an offline protocol mock and a bounded unlock runner. They are not a complete installer. Run tools in a dedicated Linux guest as described in the guide. No vendor binaries, ROMs, VM accounts or device backups are distributed here. Download vendor artifacts from the linked maintainers.

## Contributing

Start with documentation corrections, offline tests and read-only device checks. Report exact device codename, LK build, host/UTM versions and observed results. Redact serials, addresses and credentials. Never upload raw device backups. A host timeout does not prove an unlock.

This project credits amonet developers k4y0z and R0rt1z2, the amazon-oss ROM maintainers, UTM and Debian. It wraps their work; it does not claim authorship of their exploit or ROM.

Published as an experimental source preview. The manual walkthrough and app preview have different validation levels; see the linked status document before choosing either path.
