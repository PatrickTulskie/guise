# Shared by every scenario under tests/cases/: a sandboxed $HOME with stubbed
# `op`, `curl`, and `gh`; git, openssl, jq, shred are the real ones. run.sh
# sources this, then one case, in a process of its own.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The copy under test. Every case runs this one, so a build elsewhere is one
# variable away from the suite.
GUISE="${GUISE:-$ROOT/bin/guise}"
REAL_PATH="$PATH"
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi }
expect_eq() {
  local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then ok "$desc"; else bad "$desc (got '$got', want '$want')"; fi
}
expect_fail() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi }
skip() { printf '  skip  %s\n' "$1"; }

new_sandbox() {
  # pwd rather than what mktemp printed: on Git Bash that may be a Windows
  # spelling, and every path below is compared as a string.
  SB=$(cd "$(mktemp -d)" && pwd)
  export HOME="$SB/home"
  mkdir -p "$HOME"
  export XDG_CACHE_HOME="$HOME/.cache"
  export OP_FAKE_DIR="$SB/op"; mkdir -p "$OP_FAKE_DIR"
  export OP_CACHE_FAKE_DIR="$SB/op-cache"
  export OP_CACHE_LOG="$SB/op-cache.log"; : > "$OP_CACHE_LOG"
  export CURL_LOG="$SB/curl.log"; : > "$CURL_LOG"
  # What the fake GitHub has on the agent account's SSH signing keys page.
  export SIGNING_KEYS_FILE="$SB/signing_keys"; : > "$SIGNING_KEYS_FILE"
  # The sandbox's own ~/.local/bin, where setup installs: doctor checks that the
  # helpers PATH finds are those, and REAL_PATH may hold a real install's.
  export PATH="$ROOT/tests/stubs:$HOME/.local/bin:$REAL_PATH"
  export FAKE_APP_ID=1111 FAKE_SLUG=test-agent FAKE_OWNER=PatrickTulskie FAKE_INSTALL_ID=2222 FAKE_BOT_ID=3333
  export FAKE_USER_ID=4444 FAKE_LOGIN=patrick-agent
  unset FAKE_GH_LOGIN FAKE_TOKEN_EXPIRES 2>/dev/null || true
  export OP_FAKE_ACCOUNT=my.1password.com
  unset GUISE_IDENTITY GUISE_CONFIG GUISE_CO_AUTHOR 2>/dev/null || true
  # Either would send the --global writes below past the sandboxed $HOME.
  unset GIT_CONFIG_GLOBAL XDG_CONFIG_HOME 2>/dev/null || true
  # Pins which rc setup writes the shell-hook line into, so the suite asserts
  # the same path on macOS and on Linux. zsh need not be installed for this.
  export SHELL=/bin/zsh
  git config --global user.name "Human"
  git config --global user.email "human@example.com"
  git config --global commit.gpgsign true
  git config --global init.defaultBranch main
  openssl genrsa -out "$SB/key.pem" 2048 2>/dev/null
}

# No --coauthor: the hook's fallback to global user.name/email is under test.
run_setup() {
  "$GUISE" setup --owner patricktulskie --app-id 1111 \
    --op-account my.1password.com "$@" </dev/null
}

run_setup_user() {
  "$GUISE" setup --kind user \
    --op-account my.1password.com "$@" </dev/null
}

agent() { "$GUISE" "$@" </dev/null; }

new_token_file() { printf 'github_pat_stub123\n' > "$1"; }

# Paths read back from a config come in the spelling the native git stored --
# C:/Users/... on Git Bash, where MSYS rewrote the argv it was written with.
cfg() {
  local v
  v=$(git config -f "$HOME/.config/guise/config" --get "$1") || return 1
  case "$v" in [A-Za-z]:/*) cygpath -u "$v" ;; *) printf '%s\n' "$v" ;; esac
}
cfg_all() {
  git config -f "$HOME/.config/guise/config" --get-all "$1" | while read -r v; do
    case "$v" in [A-Za-z]:/*) cygpath -u "$v" ;; *) printf '%s\n' "$v" ;; esac
  done
}
# And the other way round, for a path the suite wrote and git will read back.
git_path() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
# Git Bash mounts NTFS noacl: chmod is a no-op and every file reads 644.
modes_apply() { case "$(uname -s)" in MINGW*|MSYS*) return 1 ;; *) return 0 ;; esac; }
# Root ignores modes as well, and the WSL runner is root.
perms_enforced() { modes_apply && [[ "$(id -u)" != 0 ]]; }
expect_mode() { # desc file mode
  if modes_apply; then expect_eq "$1" "$(file_mode "$2")" "$3"
  else skip "$1 (no POSIX modes on this filesystem)"; fi
}
digest() { if command -v shasum >/dev/null; then shasum; else sha1sum; fi; }

# setup names an identity after the account it belongs to, so these are the
# names the stubbed app slug and account login produce.
APP_IDENT=test-agent
USER_IDENT=patrick-agent

snapshot() {
  cat "$HOME/.gitconfig" \
      "$HOME/.zshrc" \
      "$HOME/.config/guise/hook.sh" \
      "$HOME/.config/guise/config" \
      "$HOME/.config/guise/gitconfig" \
      "$HOME/.config/guise/git/$APP_IDENT.conf" \
      "$HOME/.config/guise/git/agent-hooks/prepare-commit-msg" \
      "$HOME/.local/bin/guise-token" \
      "$HOME/.local/bin/guise-credential" \
      "$HOME/.local/bin/guise-gh" 2>/dev/null | digest | cut -d' ' -f1
}


# util-linux and BSD script disagree on where the command goes, and util-linux
# runs it with $SHELL, which the sandbox points at a zsh that may not be
# installed. BSD script hands the pty an EOF the moment its stdin closes, so
# stdin is held open until the command is done. A watchdog turns a stuck pty
# into a failure instead of a hung job.
pty_script() {
  if script --version >/dev/null 2>&1; then SHELL=/bin/bash exec script -qec "$1" /dev/null
  else exec script -q /dev/null bash -c "$1"; fi
}
in_pty() { # "command" -- stdin is what gets typed
  local done="$SB/pty.done" pid watchdog rc=0
  mkfifo "$done"
  exec 3<&0
  { cat <&3; read -r _ < "$done"; } | pty_script "$1; : > '$done'" &
  pid=$!
  exec 3<&-
  ( sleep 30; kill "$pid"; : > "$done" ) 2>/dev/null &
  watchdog=$!
  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null || true
  rm -f "$done"
  return $rc
}
# Git for Windows has no `script`, and so no way to hand the tool a terminal.
have_pty() { command -v script >/dev/null; }
