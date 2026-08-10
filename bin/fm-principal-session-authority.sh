#!/usr/bin/env bash
# fm-principal-session-authority.sh - record direct captain decisions already
# received by Firstmate in its own trusted interactive session.
#
# This is a local administrative recorder, not a relay ingress or identity
# admission surface. It accepts no captain identity claim. Network-delivered
# input remains exclusively owned by fm-principal-authority.sh, where only
# authenticated Mercury assignments are eligible and relayed captain text is
# refused as unverified context.
#
# Usage:
#   fm-principal-session-authority.sh record-captain-task [task fields]
#   fm-principal-session-authority.sh record-captain-decision [decision fields]
#
# Run --help for the complete version-matched flag surface.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node "$SCRIPT_DIR/fm-principal-session-authority.mjs" "$@"
