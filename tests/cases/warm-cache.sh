# --- warm-cache ------------------------------------------------------------------
# op-cache holds nothing until something has read through it, so after a reboot
# the first agent to need a secret is the one that meets the 1Password prompt --
# unattended, with nobody there to approve it. Warming moves that read earlier.
echo "warm-cache:"
new_sandbox
printf 'github_pat_warmed\n' > "$SB/pat.txt"
run_setup_user --store op-cache --token-file "$SB/pat.txt" >/dev/null 2>&1
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
expect_fail "a file-store identity has nothing to warm" \
  agent warm-cache --name "$APP_IDENT"
expect_fail "and an unknown one is refused outright" agent warm-cache --name nope

# A fresh login session: op-cache remembers nothing yet.
rm -rf "$OP_CACHE_FAKE_DIR"; : > "$OP_CACHE_LOG"
agent warm-cache > "$SB/warm.out" 2>&1
expect_eq "warm-cache exits 0" "$?" "0"
expect "it names the identity it warmed" grep -q "warmed '$USER_IDENT'" "$SB/warm.out"
expect_fail "and leaves the file-store one alone" grep -q "$APP_IDENT" "$SB/warm.out"
expect_fail "the secret itself never reaches the output" \
  grep -q github_pat_warmed "$SB/warm.out"
expect_eq "the read went through op-cache, keyed as guise-token will ask for it" \
  "$(cat "$OP_CACHE_LOG")" "read --account my.1password.com op://Private/patrick-agent/token"
# The whole point: a vault that locks between the warm and the first commit is
# no longer in the agent's way.
expect_eq "so the token reads back with 1Password unreachable" \
  "$(OP_FAKE_FORBID=1 "$HOME/.local/bin/guise-token" "$USER_IDENT")" "github_pat_warmed"

# An app identity's private key takes the same path.
run_setup --store op-cache >/dev/null 2>&1
rm -rf "$OP_CACHE_FAKE_DIR"; : > "$OP_CACHE_LOG"
agent warm-cache >/dev/null 2>&1
expect_eq "an app identity warms its private key, not a token" \
  "$(grep -c 'private_key' "$OP_CACHE_LOG")" "1"
expect_eq "and both identities are warmed in one run" \
  "$(wc -l < "$OP_CACHE_LOG" | tr -d ' ')" "2"
rm -f "$XDG_CACHE_HOME/guise/$APP_IDENT.token.json"
t=$(OP_FAKE_FORBID=1 "$HOME/.local/bin/guise-token" "$APP_IDENT")
expect_eq "so a JWT still signs with the vault locked" "${t:0:4}" "ghs_"

rm -rf "$OP_CACHE_FAKE_DIR"; : > "$OP_CACHE_LOG"
agent warm-cache --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "--name warms only the one it names" \
  "$(wc -l < "$OP_CACHE_LOG" | tr -d ' ')" "1"

# A login item runs this unattended, so a vault it can't reach has to be an
# exit code and not a cheerful zero.
rm -rf "$OP_CACHE_FAKE_DIR"
OP_FAKE_FORBID=1 "$GUISE" warm-cache </dev/null >/dev/null 2>&1
expect_eq "an unreachable vault fails the command" "$?" "1"

new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
agent warm-cache > "$SB/warm.out" 2>&1
expect_eq "with nothing on op-cache it still exits 0" "$?" "0"
expect "and says so" grep -q 'nothing to warm' "$SB/warm.out"

