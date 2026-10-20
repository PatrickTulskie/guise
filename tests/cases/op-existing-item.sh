# --- an item already in 1Password --------------------------------------------
# --op-item points an identity at a secret where it already lives, so moving or
# renaming the item in 1Password doesn't mean pasting the secret again.
echo "an item already in 1Password:"
new_sandbox
new_token_file "$SB/pat.txt"
run_setup_user --store op-cache --token-file "$SB/pat.txt" >/dev/null 2>&1
mkdir -p "$OP_FAKE_DIR/agents"
mv "$OP_FAKE_DIR/Private/patrick-agent" "$OP_FAKE_DIR/agents/Moved"
op-cache clear >/dev/null
agent doctor --name "$USER_IDENT" > "$SB/doctor.out" 2>&1
expect_eq "doctor fails once the item moves" "$?" "1"
expect "and its hint points at --op-item" grep -q -- "--op-item op://<vault>/<item>" "$SB/doctor.out"
run_setup_user --name "$USER_IDENT" --op-item op://agents/Moved >/dev/null 2>&1
expect_eq "--op-item points the identity at where it went" "$(cfg identity.$USER_IDENT.opitem)" "op://agents/Moved"
expect_eq "keeping the store it had" "$(cfg identity.$USER_IDENT.keysource)" "op-cache"
expect_eq "and the token reads from there" \
  "$("$HOME/.local/bin/guise-token" "$USER_IDENT")" "github_pat_stub123"
mv "$OP_FAKE_DIR/agents/Moved" "$OP_FAKE_DIR/agents/MovedAgain"
OP_FAKE_DEFAULT=work.1password.com agent setup --name "$USER_IDENT" \
  --op-item op://agents/MovedAgain >/dev/null 2>&1
expect_eq "and reads it through the account the identity is pinned to" "$?" "0"

new_sandbox
new_token_file "$SB/pat.txt"
run_setup_user --store op --vault agents --token-file "$SB/pat.txt" >/dev/null 2>&1
agent setup --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "a bare re-run leaves an item in another vault where it is" \
  "$(cfg identity.$USER_IDENT.opitem)" "op://agents/patrick-agent"
expect "rather than recreating it in the default vault" test ! -e "$OP_FAKE_DIR/Private/patrick-agent"
run_setup_user --name "$USER_IDENT" --vault elsewhere >/dev/null 2>&1
expect_eq "while --vault still moves it" \
  "$(cat "$OP_FAKE_DIR/elsewhere/patrick-agent/token")" "github_pat_stub123"

new_sandbox
mkdir -p "$OP_FAKE_DIR/agents/Held"
printf 'github_pat_held' > "$OP_FAKE_DIR/agents/Held/token"
run_setup_user --op-item op://not-a-ref >/dev/null 2>&1
expect_eq "an --op-item that isn't op://<vault>/<item> is refused" "$?" "1"
run_setup_user --op-item op://agents/Held --store file >/dev/null 2>&1
expect_eq "and so is one with --store file" "$?" "1"
run_setup_user --op-item op://agents/Nope >/dev/null 2>&1
expect_eq "and one with no token in it" "$?" "1"
expect "without writing any config" test ! -e "$HOME/.config/guise/config"
run_setup_user --op-item op://agents/Held >/dev/null 2>&1
expect_eq "a new identity can start from an item" "$?" "0"
expect_eq "landing in 1Password rather than the file a new identity defaults to" \
  "$(cfg identity.$USER_IDENT.keysource)" "op"
expect "without writing to the item" test ! -e "$OP_FAKE_DIR/agents/Held/login"
expect "or creating one of its own" test ! -e "$OP_FAKE_DIR/Private/patrick-agent"
agent setup --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "a bare re-run keeps the item it was pointed at" "$(cfg identity.$USER_IDENT.opitem)" "op://agents/Held"
expect "still without writing to it" test ! -e "$OP_FAKE_DIR/agents/Held/login"
expect "or moving it into the default vault" test ! -e "$OP_FAKE_DIR/Private/patrick-agent"
printf 'github_pat_rotated\n' > "$SB/pat.txt"
run_setup_user --name "$USER_IDENT" --op-item op://agents/Fresh --token-file "$SB/pat.txt" >/dev/null 2>&1
expect_eq "a new token alongside --op-item is stored in that item" \
  "$(cat "$OP_FAKE_DIR/agents/Fresh/token")" "github_pat_rotated"
expect_eq "which the identity then reads" "$(cfg identity.$USER_IDENT.opitem)" "op://agents/Fresh"

new_sandbox
mkdir -p "$OP_FAKE_DIR/agents/AppKey"
cp "$SB/key.pem" "$OP_FAKE_DIR/agents/AppKey/private_key"
run_setup --op-item op://agents/AppKey >/dev/null 2>&1
expect_eq "an app identity can start from an item holding its key" "$?" "0"
agent doctor --name "$APP_IDENT" >/dev/null 2>&1
expect_eq "and mints with it" "$?" "0"
mv "$OP_FAKE_DIR/agents/AppKey" "$OP_FAKE_DIR/agents/AppKeyMoved"
OP_FAKE_DEFAULT=work.1password.com agent setup --name "$APP_IDENT" \
  --op-item op://agents/AppKeyMoved >/dev/null 2>&1
expect_eq "and reads a moved one through the account it is pinned to" "$?" "0"

