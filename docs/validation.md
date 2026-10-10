# Validation boundary

Confirmed on one Mac Studio running macOS 27.2 with UTM 5.0.6 Beta, Apple Virtualization ARM64 Debian 13.7 and Intel Linux translation:

- Original bundled fastboot ran and passed the localhost mock.
- USB assignment through macOS Virtual Machine Accessories worked.
- Exact CHECKERS/LK identity was queried before unlocking.
- Original-client full payload transfer completed in 4.687 seconds but was rejected on one attempt.
- A subsequent fresh-entry run with upstream query ordering and an eight-second timeout stopped on its first timeout before download completion was reported. TWRP later appeared physically and was verified through ADB. No second or third attempt ran in that bounded run.
- Installed TWRP matched the packaged image byte for byte.
- Boot, recovery, system, userdata and metadata backups matched device-side hashes. Restore has not been tested.
- LineageOS installation completed with updater RC=0 and operation status=0. User confirmed Android setup, Wi-Fi connection and home screen.

Exact cause of the successful unlock is unresolved. Do not promise that query ordering, retry cadence, an eight-second timeout or Rosetta alone causes success. Do not infer success from a timeout. Additional devices are needed before repeatability claims.

Speaker, microphone, camera and long-term stability are not verified. Backups contain private data and stay outside this repository. Physical setup completion is user-confirmed; Android build properties were not independently queried after setup because debugging was not enabled.
