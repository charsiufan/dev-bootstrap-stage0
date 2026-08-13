#!/usr/bin/env bash

set -e
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
DEV_BOOTSTRAP_STAGE0_SOURCE_ONLY=1
. "$SCRIPT_DIR/../stage0.sh"

[ "$(detect_architecture arm64)" = "arm64" ]
[ "$(detect_architecture x86_64)" = "x86_64" ]
[ "$(homebrew_prefix_for_architecture arm64)" = "/opt/homebrew" ]
[ "$(homebrew_prefix_for_architecture x86_64)" = "/usr/local" ]
status OK "Stage 0 architecture and Homebrew prefix detection."

REQUESTED_BRANCH="refactor/declarative-bootstrap"
gh() {
    [ "$1" = "api" ] && [ "$2" = "repos/charsiufan/dev-bootstrap/git/ref/heads/refactor/declarative-bootstrap" ]
}
[ "$(select_branch)" = "$REQUESTED_BRANCH" ]
unset -f gh
REQUESTED_BRANCH=""
status OK "Stage 0 non-interactive branch validation."

temporary=$(mktemp -d "${TMPDIR:-/tmp}/dev-bootstrap-stage0-test.XXXXXX")
original_home=$HOME
HOME=$temporary
DRY_RUN=1
gh() { : > "$temporary/gh-invoked"; return 99; }
clone_bootstrap main || true
[ ! -e "$temporary/Dev/projects/dev-bootstrap" ]
[ ! -e "$temporary/gh-invoked" ]
unset -f gh
HOME=$original_home
rm -rf "$temporary"
status OK "Stage 0 dry-run clone prevention."
