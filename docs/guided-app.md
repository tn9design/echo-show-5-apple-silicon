# A guided Mac installer

The best experience is a Mac app that tells someone what to connect and shows what the Echo is doing, without exposing a terminal or requiring them to understand VM architecture.

## User flow

1. **Check this Mac:** identify macOS/CPU support, disk capacity and available tools. Explain an unsupported host before any download or device change.
2. **Prepare the workspace:** fetch publisher artifacts with pinned version/hash metadata, provision an isolated ARM Linux guest, enable Intel Linux translation and run an offline client test. No shared account or saved password in a downloadable VM.
3. **Connect the Echo:** detect USB mode and show a screenshot of the exact macOS accessory control. Apple-required user assignment stays explicit. Do not capture a mouse, keyboard or other accessory.
4. **Check compatibility:** read model/LK/lock state, select only an exact supported payload and display the matched device. Unsupported builds stop here.
5. **Unlock:** explain brick risk at this concrete action. Use bounded attempts and observable stop states. A timeout becomes “waiting for recovery verification,” never a success banner. Keep a visible powered-wait countdown. Detect changed USB enumeration and require verified recovery.
6. **Protect data:** discover partition mappings, create private host backups with verified sizes/hashes, and show exactly what is preserved. No raw-backup uploads. Preserve timestamps and checkpoint state for resume.
7. **Install:** verify ROM target and device-side hash, present a precise erase/install consent, perform only maintainer-required wipes, show real log progress and capture the terminal result before reboot.
8. **Finish:** distinguish boot animation from completed setup. Guide display wake, Wi-Fi and keeping TWRP. Offer a short hardware check and a redacted support report.

## First buildable milestone

Build a native Mac read-only preflight assistant: host inventory, publisher artifact verifier, USB mode detection, compatibility checks when fastboot is available, and a visual connection walkthrough. It must never send flash/wipe/boot/exploit commands. This delivers immediate value while unlock repeatability is studied.

Then add isolated guest provisioning, offline mock tests and recovery backup automation. Only add actual unlock/install operations after independent review and repeated device validation. Keep the transport/controller separate from the UI so its command sequence can be exercised against a mock.

## Requirements for the real installer

- Explicit state transitions and action-specific consent. No automatic destructive retries.
- No “success” derived solely from process exit/timeout; verify recovery, installer outcome and first boot separately.
- Journal operation intent and result privately; resume from observation, not by blindly replaying writes.
- Expected device/serial binding throughout; identity changes stop operations.
- Progress comes from bytes transferred or actual logs. Unknown stages say “waiting,” not invented percentages.
- Software hashes and publisher locations pinned in a versioned manifest. Upgrades require revalidation.
- Keep sensitive backups local; support export is opt-in and redacted.
- A power warning and post-exploit wait cannot be dismissed as mere UI polish.

This page describes the intended complete experience. A source preview now implements preparation, checked recovery/backup operations and a gated native installer pilot; live validation is incomplete. See [current status](prototype-status.md) and [test evidence](implementation-results.md) before using it. The earlier manual installation establishes one successful path, not universal compatibility.

## Current workspace controls

Select the pinned UTM application once per app session. Workspace preparation, lifecycle, bootstrap, validation and read-only identity checks reuse that local selection; backend ownership and version checks still run for each action. The selection is not saved across app launches. Experimental unlock retains its explicit artifact selection.

During guest bootstrap, enter the actual Linux username, not the full-name label. The recommended account is `user`, but a validated account such as `echotest` is supported. The password stays in memory for the explicit action. An account cannot change after guest credentials or device state have been established.

A stop result now states whether shutdown is still pending or the VM has stopped, with the next action in plain language. A running VM still does not establish guest readiness. Serial bootstrap remains under investigation; do not repeatedly restart or submit credentials after an unknown result.
