# Finish EchoGuide: next actions in order

**Start with step 1: prove that a fresh app-owned VM can reach authenticated guest readiness.** Do not spend more time polishing installation screens before that prerequisite works. Work in a new disposable workspace; leave the existing working Echo and VM alone.

## 1. Make the Linux workspace usable

- The disposable guest account is confirmed as `echotest`, with home `/home/echotest`. Serial-bound host-key acquisition and generated-key authorization succeeded; pinned SSH was rechecked after a graceful guest restart. Do not reset that working account or recreate its keys.
- The native app's no-password connection check now also reports `connected`. This proves app-origin SSH/account checks at that time, not translation readiness or the cause of the earlier staging failure.
- The subsequent translation action returned 127: read-only inspection found sudo missing. Do not repeat it on this guest. Add/validate the no-password sudo prerequisite on disposable fixtures first, and review the baseline account provisioning before further live work.
- On a properly prepared fresh guest, run the explicit native translation setup once using the private password field. Inspect its outcome; a failed or interrupted privileged setup retains a pending-intent marker and must not be replayed automatically.
- After successful setup, gracefully restart the owned guest and validate the original pinned client with the offline protocol helper. Recheck translation and client readiness after restart.
- Validate fresh native serial login/bootstrap, private identity uniqueness and readiness on a second clean workspace. Include changed guest addresses, interruptions and unrelated-VM preservation. Work in isolated app sessions (`--state-root ABSOLUTE_DIRECTORY`).
- Keep the serial harness regression checks: unknown prompts or incomplete frames stop without submitting credentials. Use the native no-password connection check for app-origin transport failures; terminal/MCP results have a different permission context.

**Done when:** two fresh workspaces have different credentials and host keys, both pass the offline client test after restart, and no unrelated VM changes. Keep the cloud-image shortcut deferred until this baseline passes.

## 2. Finish recovery selection and backup handling

- Validate the implemented structured ADB picker and CHECKERS/TWRP reinspection on a recovery device.
- Validate the implemented measured backup progress and explicit interrupted-read recovery path on an authorized recovery device. Never resume a partial capture as verified.
- Exercise the adapter on an authorized compatible recovery device, including mount restoration and device/host hash comparisons.

**Done when:** all five required images and their manifest verify, disconnect/full-disk cases stop safely, and a failed or missing image prevents an installation request. Restoration remains unavailable.

## 3. Complete the assistant handoff

- Validate the new no-argument `prepare_workspace` flow after native UTM/ISO selection. Its operation ID is reservation evidence; successful VM creation still does not establish guest readiness.
- Extend the completed ephemeral Codex powered-wait smoke to progress and native request handoffs, and test Claude Desktop. Persistent client configurations remain untested.
- Verify that a request reaches the running app, displays the exact action/device, and cannot be approved by the assistant.
- Check app-closed, stale-request, concurrent-operation and changed-device behavior.

**Done when:** both clients can inspect progress and request the appropriate native interaction without providing paths, shell commands or approval decisions.

## 4. Connect the supervised installer

- Integrate the reviewed bounded unlock sequence, operation journal, powered wait and independent recovery verification.
- Validate the implemented native pinned-ROM chooser and device-side staging action on an authorized recovery device before any erase confirmation. Offline checked-wrapper tests and app compilation passed; no fresh live staging was performed.
- Connect wipes, installation, current-invocation log verification, log preservation and reboot to the native approval path.
- Test crashes and ambiguous results with fake runners before enabling any live dispatch.

**Done when:** missing prerequisites and uncertain results stop before further writes; no interrupted write is automatically replayed. Offer live execution only as an explicitly experimental pilot.

## 5. Reproduce and package

- Invite owners of additional matching units to informed, supervised trials; do not re-unlock the already-working Echo.
- Record setup/home-screen and individual hardware checks, plus hands-on and total elapsed time.
- Supply private signing/notary credentials and verify signed automation, notarization and installation on a clean Mac account. The extracted source archive already passes a local production build and matching CLI/MCP smoke checks; signing remains unverified.
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
