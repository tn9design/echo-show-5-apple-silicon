---
name: echo-guide
description: Guide a first-generation CHECKERS Echo Show 5 through EchoGuide on Apple Silicon macOS, using its local checked workflow and native approvals. Use for EchoGuide installation, readiness checks, recovery backups, or troubleshooting.
---

Use the installed EchoGuide MCP tools or companion CLI. Read [integration guidance](references/ai-integration.md) for setup and the current release limitations. If the backend is unavailable, help set it up; do not substitute a hand-written unlock or wipe command.

1. Inspect host readiness and session status. USB visibility is not compatibility proof. Do not claim an unsupported build works.
2. Explain the next physical action shown by the backend. Leave wall power connected during an unlock and its five-minute waiting period. USB assignment must target the session's managed VM, never another accessory.
3. For unlock or installation, request native approval and explain the exact action. A pending request is not execution or authorization. The person approves in the Mac app; no MCP approval tool exists.
4. After interruption, read status and recheck identity. Never replay a device write because a previous call failed or timed out. A timeout does not prove unlock success; compatible recovery must be independently verified.
5. Use `verify_recovery` and then `backup` after the person selects the device, ADB executable, and private destination in the native app. These tools accept no paths or device identifiers from the assistant. Require verified backups before ROM installation. Backups represent the pre-ROM state after unlocking, may contain credentials, and do not provide a proven factory restore. Never upload or include them in reports.
6. Report only observed outcomes. Without authorized Android debugging, ask the person to confirm setup/home screen. Leave Update Lineage Recovery unchecked to retain TWRP. Record Wi-Fi, touch, audio, microphone, camera, and reboot checks individually.

Use `report` for shareable diagnostics and let the person review it. Do not share raw session state, private paths, addresses, full serials, passwords, or keys. Do not expose arbitrary commands, change retry timing/payloads, bypass approval, or disable Gatekeeper. Preparation and approval requests in preview builds are not a finished installer.

Client validation is narrow: an ephemeral Codex read-only powered-wait call passed. Do not infer approval, backup, or installation client validation, and do not describe Claude Desktop as tested.
