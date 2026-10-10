# Source preview implementation results

The integrated app, shared core, CLI and MCP build successfully on the development Mac using local temporary build staging. The expanded run passed 52 XCTest cases with no failures. Tests use temporary fixtures and fake runners; they do not connect to an Echo, create a VM, or prove unlock repeatability.

The app now selects recovery candidates from structured ADB results. Interrupted read/backup operations require explicit reinspection of the same recovery device and invalidate prior backup/install evidence. Interrupted writes cannot use this path. Owned-VM reconciliation, start and graceful shutdown use exact ownership markers and the recorded UUID; absent or ambiguous results retain creation intent. The new UI and lifecycle scripting have not been tested against a running VM.

Owned serial-channel discovery is implemented against UTM 5.0.6's scripting dictionary and tagged source. It requires a running Apple VM, exact ownership/UUID binding and one PTY port. It does not open the channel; login, bootstrap and host-key acquisition remain unfinished.

Offline CLI/MCP smoke checks passed: initialization, tool listing, ping, malformed JSON, rejection of caller paths/approval tools, isolated session creation, and rejection of installation without prerequisites.

Source packaging and shell syntax checks passed. A source ZIP includes tools, profile, app/core/interface sources, tests, skill, docs and license; it omits personal backups, VM images and credentials.

See prototype-status.md for remaining live-validation and implementation gates. This does not mark all milestones complete.

Independent reviewers reproduced and then confirmed fixes for stale same-ROM success logs, absent backup manifests, and OpenSSH configuration paths. Revised source archive helper inclusion was independently checked.

The launch script refused to overwrite/relaunch an already-running EchoGuide instance, as intended. The new native window/button flow was not visually verified in this pass.
