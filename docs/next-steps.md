# Finish EchoGuide: next actions in order

**Start with step 1: prove that a fresh app-owned VM can reach authenticated guest readiness.** Do not spend more time polishing installation screens before that prerequisite works. Work in a new disposable workspace; leave the existing working Echo and VM alone.

## 1. Make the Linux workspace usable

- Create a fresh VM through the adapter and record its ownership UUID.
- Validate keyboard/pointer input or the serial installer route, then install the pinned Debian baseline.
- Enable translation and confirm it survives a guest restart.
- Connect the owned serial channel to the host-key acquisition code; pin the actual guest key before SSH.
- Wire account/key setup, verified asset staging and readiness checks into the app.

**Done when:** two fresh workspaces have different credentials and host keys, both pass the offline client test after restart, and no unrelated VM changes. Keep the cloud-image shortcut deferred until this baseline passes.

## 2. Finish recovery selection and backup handling

- Validate the implemented structured ADB picker and CHECKERS/TWRP reinspection on a recovery device.
- Add clear backup progress and validate the implemented explicit interrupted-read recovery path. Never resume a partial capture as verified.
- Exercise the adapter on an authorized compatible recovery device, including mount restoration and device/host hash comparisons.

**Done when:** all five required images and their manifest verify, disconnect/full-disk cases stop safely, and a failed or missing image prevents an installation request. Restoration remains unavailable.

## 3. Complete the assistant handoff

- Test the documented MCP configuration in Codex and Claude Desktop.
- Verify that a request reaches the running app, displays the exact action/device, and cannot be approved by the assistant.
- Check app-closed, stale-request, concurrent-operation and changed-device behavior.

**Done when:** both clients can inspect progress and request the appropriate native interaction without providing paths, shell commands or approval decisions.

## 4. Connect the supervised installer

- Integrate the reviewed bounded unlock sequence, operation journal, powered wait and independent recovery verification.
- Add ROM staging and device-side hash verification before the erase confirmation.
- Connect wipes, installation, current-invocation log verification, log preservation and reboot to the native approval path.
- Test crashes and ambiguous results with fake runners before enabling any live dispatch.

**Done when:** missing prerequisites and uncertain results stop before further writes; no interrupted write is automatically replayed. Offer live execution only as an explicitly experimental pilot.

## 5. Reproduce and package

- Invite owners of additional matching units to informed, supervised trials; do not re-unlock the already-working Echo.
- Record setup/home-screen and individual hardware checks, plus hands-on and total elapsed time.
- Supply private signing/notary credentials, build the app, and verify installation on a clean Mac account.
- Publish a release with a short user walkthrough, checksums, observed outcomes and known limits.

**Done when:** at least two additional independent installations and the packaging checks pass. Do not promise an unlock success rate from this small sample.

## Run the checks while developing

From the repository root:

```bash
swift test --scratch-path /private/tmp/EchoGuideChecks
python3 script/test-ai-interfaces.py "$(swift build --scratch-path /private/tmp/EchoGuideChecks --show-bin-path)"
bash script/package-release.sh /private/tmp/EchoGuideSourceRelease
```

These checks use offline fixtures. They do not establish live device compatibility or complete the validation milestones above.
