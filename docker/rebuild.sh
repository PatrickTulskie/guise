#!/usr/bin/env bash
# Rebuild the sandbox's guise from the working tree, after an edit on the host.
set -euo pipefail
exec go build -o "${GUISE:?GUISE is set by the sandbox entrypoint}" /work/cmd/guise
