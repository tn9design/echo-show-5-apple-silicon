# Preparation prototype status

Implemented native SwiftUI host/USB checks, user-selected manifest verification and pinned UTM5.0.6/Lineage CHECKERS v0.7 download preparation. Completed downloads require HTTP200 and expected SHA-256 before moving into the chosen destination. Verified existing files are reused. Existing mismatches stop without replacement. No device-write command dispatcher exists in the app.

Validation: Swift build and local app launch/process check passed. Three XCTest cases passed: known SHA-256 vector, verified file reuse without network, mismatch preserves existing file. Network-share test signing initially failed because of filesystem metadata; script now uses local temporary build/app storage.

Initial window and controls inspected via accessibility. Subsequent computer-control calls dropped their native connection. Full button interaction, publisher network-download handling and export/distribution signing remain unverified. Tests used local fixtures and did not access the Echo or fetch large files.

Next: supported isolated UTM guest provisioning, guest readiness/original-client validation, private verified backup assistant, and only later supervised installation. A first successful device does not establish unlock repeatability.
