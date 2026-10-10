# Native pilot build boundary

The normal source build is a preparation preview. `NativePilotCoordinator.buildMode` reports `preparationPreview`, and its factory refuses before showing destructive confirmation or running commands. No environment variable or runtime preference enables writes.

The internal native composition is intended for the supervised Milestone C pilot, before wider release. A deliberately audited source build can compile the facade's gate with:

```sh
swift build --disable-sandbox -Xswiftc -DECHOGUIDE_EXPERIMENTAL_PILOT
```

The flag changes the app-facing build indicator to `experimentalPilot` and selects the native app’s experimental confirmation branch. The default build retains review/decline only. The experimental branch binds the confirmation to the actual SwiftUI view’s owning native window; a missing or closed window is not replaced by another window. Unlock requires explicit native selection of UTM and the pinned developer payload. Installation uses the configured recovery/ROM state and asks for neither UTM nor a payload. No file is selected automatically. Cancelling a picker leaves the request pending and runs no device command.

The flag does not approve requests, provide verified prerequisites, provision a workspace, or bypass host/device/build checks. UI compilation is not live workflow proof: the experimental branch has not been exercised against an Echo through the new app. Do not describe this source build as a finished installer.

Unlock composition requires the exact identified device/build, pinned payload bytes, selected pinned UTM version, running owned Apple VM, authenticated guest trust, fresh translation/client checks, native confirmation, and the bounded powered-wait procedure. Installation from compatible recovery uses configured host ADB, verified backups and the pinned staged ROM; it does not require a Linux VM or previously verified stock bootloader.

The native confirmation shows the exact action, device, expiry and artifact hash. Cancel is the default. Closure or cancellation invalidates a pending review. The dispatcher independently refreshes prerequisites under operation ownership and consumes approval before device writes. Timeout never counts as unlock success, and Android startup remains a separate human observation.

The compile flag does not promote the workflow to a wider release. Independent supported-device installations, clean-workspace provisioning, interruption tests, packaging and signing remain separate evidence. Do not disable Gatekeeper; use the normal source-build workflow while signed distribution is unavailable.
