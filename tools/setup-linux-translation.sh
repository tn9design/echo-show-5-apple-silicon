#!/bin/bash
# Canonical reviewed guest script is bundled with the shared engine.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec /bin/bash "$script_dir/../Sources/EchoGuideCore/Resources/setup-linux-translation.sh" "$@"
