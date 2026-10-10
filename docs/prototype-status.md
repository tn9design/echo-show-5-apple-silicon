# Implementation and validation status

This is an experimental source preview, not a finished installer. No live unlock/wipe/install dispatcher is enabled in the app, CLI, or MCP server.

Implemented: shared Swift workflow library; pinned compatibility profile; structured USB enumeration; private persisted sessions and process locks; native approval requests; guided SwiftUI app; profile-based downloads with measured byte progress, cancellation, size/hash validation and safe destinations; CLI and stdio MCP; portable assistant skill; MIT license; source/signing packaging scripts.

Adapters implemented with injectable runners: UTM 5.0.6 owned-VM creation, compatible TWRP identification, named partition discovery, streamed private backups with mount/space/size/hash checks, unique SSH client credentials, VM-bound host-key pinning, verified guest validation asset staging and offline guest readiness. These are exercised with local fixtures. One fresh owned-VM creation, ownership reconciliation and Debian installer boot through native UTM Run were also verified live; automated scripting startup returned AppleEvent timeout and remains unresolved; the guest and backup integrations remain unverified.

Internal pilot code tests identity/rejection parsing and installation stop conditions. Current-invocation recovery log evidence is required; stale successes never authorize reboot. The reviewed standalone bounded unlock script remains a separate experimental developer tool with explicit execution, pinned hashes and exact ordinary-rejection classification. It is not called by the GUI/MCP.

Still required before Milestone A is complete: fresh managed VM install/input configuration and lifecycle validation; live native serial login and host-key acquisition; end-to-end authenticated guest bootstrap; clean-host and guest-restart checks. The shared engine and app have an explicit memory-only serial login/bootstrap path, bounded PTY transport, challenge-bound identity parsing and client-key installation. Transport tests use isolated host PTYs; protocol tests use fixtures. No live VM bootstrap is proven. The cloud-image provisioning path is deferred until this baseline works. VM creation alone never means guest readiness.

Still required before Milestone B is complete: live authorized recovery/backup validation, live interruption checks, and client integration tests. Structured recovery selection, measured backup progress and explicit interrupted-read reinspection have offline tests. Existing app-owned backup destinations are not overwritten; interrupted partial captures remain incomplete and require a fresh destination.

Still required before Milestone C: native approved dispatch integration, complete timed unlock orchestration/powered waiting UI, additional independent device trials, and hardware checks. The existing working Echo is not a test target.

Distribution: no signing identities were available in the inspected host keychain. The packaging script produces source previews without credentials and signs/notarizes only when private identity and notary profile are supplied. Notarization and fresh publisher downloads have not been tested.

The test count and release evidence are recorded in docs/implementation-results.md. Client configuration examples are not claims of tested Claude/Codex integrations.
