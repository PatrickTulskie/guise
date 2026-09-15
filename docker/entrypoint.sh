#!/usr/bin/env bash
# Drops whatever runs next into the same fake world the suite uses: stubbed op,
# curl and gh ahead of everything on PATH, a scratch $HOME nothing outlives, and
# no route to the real GitHub or 1Password.
#
# The FAKE_* values match tests/run.sh, so a hand-run here and a test failure
# are describing the same account.
set -euo pipefail

ROOT=/work
SB="$HOME/sandbox"

export PATH="$ROOT/tests/stubs:$ROOT/bin:$HOME/.local/bin:$PATH"
export XDG_CACHE_HOME="$HOME/.cache"
export SHELL="${SHELL:-/bin/bash}"

export OP_FAKE_DIR="$SB/op"
export OP_FAKE_ACCOUNT=my.1password.com
export CURL_LOG="$SB/curl.log"
export SIGNING_KEYS_FILE="$SB/signing_keys"
export FAKE_APP_ID=1111 FAKE_SLUG=test-agent FAKE_OWNER=PatrickTulskie
export FAKE_INSTALL_ID=2222 FAKE_BOT_ID=3333
export FAKE_USER_ID=4444 FAKE_LOGIN=patrick-agent

mkdir -p "$OP_FAKE_DIR" "$HOME/.local/bin"
: > "$CURL_LOG"
: > "$SIGNING_KEYS_FILE"

# A login shell rebuilds PATH from /etc/profile, which would drop the stubs and
# quietly put the real world back in front of guise.
printf 'export PATH=%s\n' "$PATH" > "$HOME/.zshenv"
printf '\nexport PATH=%s\n' "$PATH" >> "$HOME/.profile"

# The app path wants a private key to file away, and setup shreds the one it is
# given -- so leave a fresh one here every run rather than once at build time.
openssl genrsa -out "$SB/app-key.pem" 2048 2>/dev/null
chmod 600 "$SB/app-key.pem"

if [[ -t 1 ]]; then
  cat <<BANNER

guise sandbox -- host $(uname -n), throwaway \$HOME, fake GitHub and 1Password.
Nothing here reaches the network and nothing survives the container.

  guise            /work/bin/guise, straight off your working tree
  app identity     --owner PatrickTulskie --app-id 1111 --pem ~/sandbox/app-key.pem
  user identity    --login patrick-agent, and any string as the token
  1Password        vault "Private", stored as files under ~/sandbox/op
  API calls        logged to ~/sandbox/curl.log
  signing keys     what the fake account has published: ~/sandbox/signing_keys

BANNER
fi

exec "$@"
