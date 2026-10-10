# Source preview implementation results

The integrated app, shared core, CLI and MCP build successfully on the development Mac using local temporary build staging. The expanded run passed 72 XCTest cases with no failures. Tests use temporary fixtures, fake runners and isolated host PTYs; they do not connect to an Echo, create a VM, or prove unlock repeatability.

The project-authored offline protocol helper is bundled and hash-verified, removing its file picker. Client/helper hashes now come from the versioned compatibility profile. A resource test caught a missing Python file in the generated bundle; explicit copy-resource packaging fixes it and the test verifies equality with the source helper.

The Debian-only translation script now installs a persistent read-only virtiofs mount and orders binfmt-support after it. Three offline script checks and shell syntax passed. No guest restart was performed, so persistence is implemented but remains live-unverified.

Experimental app controls now request bootstrap and offline guest validation. Guest trust is persisted privately, omitted from diagnostic exports, and invalidated for readiness after managed start/stop actions. Validation reacquires serial identity before SSH, supports a changed private guest address, rejects a changed host key, stages only hash-verified validation assets and records the offline result. The app can make one bounded serial login attempt as `user` using a memory-only password. Accepted and rejected exchanges pass isolated PTY tests; the actual Debian VM flow remains unverified. A graphical-console login is not used as serial authentication.

The app now selects recovery candidates from structured ADB results. Interrupted read/backup operations require explicit reinspection of the same recovery device and invalidate prior backup/install evidence. Interrupted writes cannot use this path. Owned-VM reconciliation, start and graceful shutdown use exact ownership markers and the recorded UUID; absent or ambiguous results retain creation intent. The new UI and lifecycle scripting have not been tested against a running VM.

Owned serial-channel discovery is implemented against UTM 5.0.6's scripting dictionary and tagged source. It requires a running Apple VM, exact ownership/UUID binding and one PTY port. The explicit shared-engine bootstrap path opens the verified character device, bounds reads/writes, uses fresh challenge framing, creates a unique client key, installs its public half and pins the unchanged guest host key before SSH. Native login is available through the temporary password field. Interrupted key creation is not overwritten automatically. Guest provisioning, visual interaction and live host-key acquisition remain unverified or unfinished; no guest commands ran during these checks.

Offline CLI/MCP smoke checks passed: initialization, tool listing, ping, malformed JSON, rejection of caller paths/approval tools, isolated session creation, and rejection of installation without prerequisites.

Source packaging and shell syntax checks passed. A source ZIP includes tools, profile, app/core/interface sources, tests, skill, docs and license; it omits personal backups, VM images and credentials.

See prototype-status.md for remaining live-validation and implementation gates. This does not mark all milestones complete.

Independent reviewers reproduced and then confirmed fixes for stale same-ROM success logs, absent backup manifests, and OpenSSH configuration paths. Revised source archive helper inclusion was independently checked.

The launch script refused to overwrite/relaunch an already-running EchoGuide instance, as intended. The new native window/button flow was not visually verified in this pass.

Measured backup progress is available in the app and private session status. Four offline transfer tests cover intermediate byte counts, corruption, transfer exceptions and mount-restoration failure. Captured bytes never substitute for size/hash verification; completion follows verified images, restored mounts and manifest creation. Live backup progress and UI rendering remain unverified.

A live fresh-workspace check on macOS 27.2 with pinned UTM 5.0.6 and the hash-matched Debian ISO exposed AppleScript error -1700: the `serial ports` record key resolved to the serial-port class. The creation script now uses the exact `SrPt` configuration field code from the shipped dictionary. A new isolated VM was created successfully, and ownership reconciliation returned its recorded UUID, Apple backend and stopped state. Earlier failed ownership intents were retained and independently found absent. No VM was booted and no Echo command ran in this check; guest install/login/readiness and the two-workspace acceptance gate remain open.

A subsequent explicit start of that isolated VM failed. The native UTM library and independent ownership inspection continued to report stopped; the Debian ISO remained selected. The first failure discarded the underlying scripting diagnostic, so its cause is unknown. Lifecycle failures now retain bounded local stderr, and the CLI exposes checked start/stop workspace operations. These operations do not imply guest readiness or authorize Echo writes. The next explicit diagnostic start returned AppleEvent timed out (-1712); this establishes a scripting timeout, not a successful boot or its underlying cause. No overlapping lifecycle command or Echo write was issued.
