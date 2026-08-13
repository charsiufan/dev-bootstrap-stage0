#!/usr/bin/env bash

set -u
set -o pipefail

DRY_RUN=0
REQUESTED_BRANCH=""
REPOSITORY="charsiufan/dev-bootstrap"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --branch)
            [ "$#" -ge 2 ] || { printf '[WARNING] --branch requires a value.\n' >&2; exit 2; }
            REQUESTED_BRANCH=$2
            shift 2
            ;;
        *) printf '[WARNING] Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

status() { printf '[%s] %s\n' "$1" "$2"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

detect_architecture() {
    case "${1:-$(uname -m)}" in
        arm64|aarch64) printf 'arm64\n' ;;
        x86_64|amd64) printf 'x86_64\n' ;;
        *) return 1 ;;
    esac
}

homebrew_prefix_for_architecture() {
    case "$1" in
        arm64) printf '/opt/homebrew\n' ;;
        x86_64) printf '/usr/local\n' ;;
        *) return 1 ;;
    esac
}

refresh_brew_environment() {
    local architecture prefix brew_bin shell_environment
    architecture=$(detect_architecture) || return 1
    prefix=$(homebrew_prefix_for_architecture "$architecture") || return 1
    if command_exists brew; then brew_bin=$(command -v brew)
    elif [ -x "$prefix/bin/brew" ]; then brew_bin="$prefix/bin/brew"
    else return 1
    fi
    shell_environment=$($brew_bin shellenv 2>/dev/null) || return 1
    eval "$shell_environment"
}

ensure_command_line_tools() {
    if xcode-select -p >/dev/null 2>&1; then
        status KEEP "Xcode Command Line Tools already installed."
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        status DRY-RUN "Would initiate Xcode Command Line Tools installation."
        return 1
    fi
    status INSTALL "Requesting Xcode Command Line Tools installation..."
    xcode-select --install >/dev/null 2>&1 || true
    status CHECK "Complete the Apple installer, then rerun stage0.sh."
    return 1
}

ensure_homebrew() {
    if refresh_brew_environment; then
        status KEEP "Homebrew already installed."
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        status DRY-RUN "Would install Homebrew using the supported installer."
        return 1
    fi
    status INSTALL "Homebrew"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
    refresh_brew_environment
}

ensure_brew_package() {
    local command_name package
    command_name=$1; package=$2
    if command_exists "$command_name"; then status KEEP "$command_name already available."; return 0; fi
    if brew list --formula "$package" >/dev/null 2>&1; then
        status CHECK "$package is installed but '$command_name' is unavailable in PATH."
        return 1
    fi
    if [ "$DRY_RUN" -eq 1 ]; then status DRY-RUN "Would install $package with Homebrew."; return 1; fi
    status INSTALL "$package"
    brew install "$package" || return 1
    refresh_brew_environment
    command_exists "$command_name"
}

github_authenticated() {
    gh auth status --hostname github.com >/dev/null 2>&1
}

authenticate_github() {
    if github_authenticated; then status OK "GitHub authenticated."; return 0; fi
    if [ "$DRY_RUN" -eq 1 ]; then status DRY-RUN "Would initiate interactive GitHub authentication."; return 1; fi
    status CHECK "GitHub authentication required; a browser sign-in will open."
    gh auth login --hostname github.com --git-protocol https --web || return 1
    github_authenticated
}

branch_exists() {
    gh api "repos/$REPOSITORY/git/ref/heads/$1" >/dev/null 2>&1
}

select_branch() {
    local default_branch branches selection selected index branch
    if [ -n "$REQUESTED_BRANCH" ]; then
        branch_exists "$REQUESTED_BRANCH" || { status WARNING "Branch does not exist: $REQUESTED_BRANCH"; return 1; }
        printf '%s\n' "$REQUESTED_BRANCH"
        return 0
    fi
    default_branch=$(gh api "repos/$REPOSITORY" --jq .default_branch) || return 1
    branches=$(gh api --paginate "repos/$REPOSITORY/branches" --jq '.[].name') || return 1
    printf '\nBootstrap branch\n\n' >&2
    index=1
    while IFS= read -r branch; do
        if [ "$branch" = "$default_branch" ]; then printf '  %d. %s [default]\n' "$index" "$branch" >&2
        else printf '  %d. %s\n' "$index" "$branch" >&2; fi
        index=$((index + 1))
    done <<EOF
$default_branch
$(printf '%s\n' "$branches" | grep -Fvx "$default_branch")
EOF
    printf '\nSelect branch [1]: ' >&2
    if [ -r /dev/tty ]; then
        IFS= read -r selection < /dev/tty
    else
        selection=""
    fi
    [ -n "$selection" ] || selection=1
    case "$selection" in
        *[!0-9]*) selected=$selection ;;
        *) selected=$(printf '%s\n%s\n' "$default_branch" "$(printf '%s\n' "$branches" | grep -Fvx "$default_branch")" | sed -n "${selection}p") ;;
    esac
    [ -n "$selected" ] && branch_exists "$selected" || { status WARNING "Invalid bootstrap branch selection."; return 1; }
    printf '%s\n' "$selected"
}

clone_bootstrap() {
    local branch destination_root destination attempt output
    branch=$1
    destination_root="$HOME/Dev/projects"
    destination="$destination_root/dev-bootstrap"
    if [ -d "$destination/.git" ]; then status KEEP "dev-bootstrap already cloned; existing repository left unchanged."; return 0; fi
    [ ! -e "$destination" ] || { status WARNING "Destination exists but is not a Git repository: $destination"; return 1; }
    if [ "$DRY_RUN" -eq 1 ]; then status DRY-RUN "Would clone $REPOSITORY branch '$branch' -> $destination"; return 1; fi
    mkdir -p "$destination_root" || return 1
    attempt=1
    while [ "$attempt" -le 3 ]; do
        status CLONE "$REPOSITORY branch '$branch' -> $destination"
        output=$(gh repo clone "$REPOSITORY" "$destination" -- --branch "$branch" 2>&1)
        if [ "$?" -eq 0 ] && git -C "$destination" rev-parse --git-dir >/dev/null 2>&1; then return 0; fi
        if [ -e "$destination" ] && [ ! -d "$destination/.git" ]; then rm -rf "$destination"; fi
        if printf '%s' "$output" | grep -Eqi 'repository not found|permission denied|authentication failed|remote branch .* not found'; then break; fi
        attempt=$((attempt + 1))
        if [ "$attempt" -le 3 ]; then status RETRY "Clone failed; retrying ($attempt/3)..."; sleep 5; fi
    done
    status WARNING "Could not clone dev-bootstrap."
    return 1
}

main() {
    local branch bootstrap_script
    [ "$(uname -s)" = "Darwin" ] || { status WARNING "stage0.sh must run on macOS."; return 1; }
    printf '\n========================================\n Development Bootstrap - Stage 0 (macOS)\n========================================\n\n'
    ensure_command_line_tools || return $?
    ensure_homebrew || return $?
    ensure_brew_package git git || return $?
    ensure_brew_package gh gh || return $?
    authenticate_github || return $?
    branch=$(select_branch) || return 1
    status OK "Bootstrap branch: $branch"
    if ! clone_bootstrap "$branch"; then [ "$DRY_RUN" -eq 1 ] && return 0; return 1; fi
    bootstrap_script="$HOME/Dev/projects/dev-bootstrap/mac/bootstrap.sh"
    [ -f "$bootstrap_script" ] || { status WARNING "Main bootstrap script not found: $bootstrap_script"; return 1; }
    if [ "$DRY_RUN" -eq 1 ]; then /bin/bash "$bootstrap_script" --dry-run; else /bin/bash "$bootstrap_script"; fi
}

if [ "${DEV_BOOTSTRAP_STAGE0_SOURCE_ONLY:-0}" -eq 0 ]; then
    main
fi
