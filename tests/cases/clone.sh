# --- clone ---------------------------------------------------------------------
# Real git, no network: rewrite the github.com URL clone builds to a local bare
# repo, so what gets asserted is where the clone lands.
echo "clone:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store file --name platform --pem "$SB/key2.pem" >/dev/null 2>&1
mkdir -p "$SB/origins/owner"
for r in one two three four five; do git init -q --bare "$SB/origins/owner/$r.git"; done
git config --global url."$SB/origins/".insteadOf "https://github.com/"

( cd "$HOME/agentic-code/platform" && agent clone owner/one ) >/dev/null 2>&1
expect "clone from inside an agent directory uses that agent" \
  test -d "$HOME/agentic-code/platform/one/.git"
expect "and not the default identity" test ! -e "$HOME/agentic-code/$APP_IDENT/one"
( cd "$HOME/agentic-code/platform" && agent clone owner/two --name "$APP_IDENT" ) >/dev/null 2>&1
expect "--name still wins over the current directory" \
  test -d "$HOME/agentic-code/$APP_IDENT/two/.git"
mkdir -p "$HOME/agentic-code/notanidentity"
( cd "$HOME/agentic-code/notanidentity" && agent clone owner/three ) >/dev/null 2>&1
expect "a directory under the base dir that is not an identity falls back" \
  test -d "$HOME/agentic-code/$APP_IDENT/three/.git"
( cd "$HOME" && agent clone owner/four ) >/dev/null 2>&1
expect "clone from outside the base directory uses the default" \
  test -d "$HOME/agentic-code/$APP_IDENT/four/.git"

# An identity with a workspace of its own: both the destination and the
# identity inferred from the current directory come from the override.
agent basedir "$HOME/own-root" --name platform >/dev/null 2>&1
git init -q --bare "$SB/origins/owner/six.git"
( cd "$HOME/own-root/platform" && agent clone owner/six ) >/dev/null 2>&1
expect "clone follows an identity to its own workspace" \
  test -d "$HOME/own-root/platform/six/.git"
expect "and the earlier clones came along" test -d "$HOME/own-root/platform/one/.git"
agent basedir --unset --name platform >/dev/null 2>&1
expect "--unset brings them back under the shared workspace" \
  test -d "$HOME/agentic-code/platform/six/.git"

# setup keeps the path it was given, so both spellings of the same basedir have
# to resolve the same identity.
git config -f "$HOME/.config/guise/config" core.basedir "$HOME/agentic-code/"
( cd "$HOME/agentic-code/platform" && agent clone owner/five ) >/dev/null 2>&1
expect "a trailing slash on basedir still selects the current identity" \
  test -d "$HOME/agentic-code/platform/five/.git"

# A basedir of / puts identity directories at the root, so this one clone
# lands outside the sandbox by definition. Keep the destination unpredictable
# and take it away again. On Windows / is Git's install directory and /tmp sits
# under the profile, so no identity named tmp can own it.
if [[ -n "$EXE" ]]; then
  skip "a root basedir treats an absolute current directory as contained (no POSIX root on Windows)"
else
  root_dest=$(mktemp -d /tmp/guise-root.XXXXXX)
  root_repo=${root_dest##*/}
  # clone refuses an existing destination, even an empty one.
  rmdir "$root_dest"
  git init -q --bare "$SB/origins/owner/$root_repo.git"
  git config -f "$HOME/.config/guise/config" --rename-section identity.platform identity.tmp
  git config -f "$HOME/.config/guise/config" core.basedir /
  root_cwd=$(mktemp -d /tmp/guise-root.XXXXXX)
  ( cd "$root_cwd" && agent clone "owner/$root_repo" ) >/dev/null 2>&1
  expect "a root basedir treats an absolute current directory as contained" \
    test -d "$root_dest/.git"
  rm -rf "$root_cwd" "$root_dest"
fi

