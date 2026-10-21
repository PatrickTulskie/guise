# --- 1Password account pinning -----------------------------------------------
# Unpinned, reads go to whichever account op defaults to, which signing in to a
# second one can change.
echo "1Password account pinning:"
new_sandbox
new_token_file "$SB/pat.txt"
agent setup --kind user --store op --token-file "$SB/pat.txt" >/dev/null 2>&1
expect_eq "setup with no --op-account pins the account op answered for" \
  "$(cfg identity.$USER_IDENT.opaccount)" "my.1password.com"
OP_FAKE_DEFAULT=work.1password.com agent setup --kind user >/dev/null 2>&1
expect_eq "a re-run once another account is op's default exits 0" "$?" "0"
expect_eq "and keeps the account it pinned" \
  "$(cfg identity.$USER_IDENT.opaccount)" "my.1password.com"
git config -f "$HOME/.config/guise/config" --unset identity.$USER_IDENT.opaccount
agent doctor --name "$USER_IDENT" > "$SB/doctor.out" 2>&1
expect_eq "doctor still passes for an identity set up before pinning" "$?" "0"
expect "but warns it is unpinned" grep -q "warn  1Password account pinned" "$SB/doctor.out"
agent setup --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "re-running its setup pins it" \
  "$(cfg identity.$USER_IDENT.opaccount)" "my.1password.com"
git config -f "$HOME/.config/guise/config" --unset identity.$USER_IDENT.opaccount
OP_FAKE_DEFAULT=work.1password.com agent doctor --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "unpinned, its reads break once another account is op's default" "$?" "1"
OP_FAKE_DEFAULT=work.1password.com agent setup --name "$USER_IDENT" \
  --op-account my.1password.com >/dev/null 2>&1
expect_eq "and setup with --op-account reads it back from the right one" "$?" "0"
OP_FAKE_DEFAULT=work.1password.com agent doctor --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "leaving it pinned there" "$?" "0"
git config -f "$HOME/.config/guise/config" identity.$USER_IDENT.opaccount other.1password.com
new_token_file "$SB/pat2.txt"
FAKE_LOGIN=second-agent agent setup --kind user --store op --token-file "$SB/pat2.txt" >/dev/null 2>&1
expect_eq "a new identity set up beside a pinned default exits 0" "$?" "0"
expect_eq "and pins the account op answered for, not the default's" \
  "$(cfg identity.second-agent.opaccount)" "my.1password.com"
# With no --name, --op-account speaks for the default identity, the same as
# naming it would: its item is read from there, or nowhere.
git config -f "$HOME/.config/guise/config" identity.$USER_IDENT.opaccount my.1password.com
mkdir -p "$OP_FAKE_DIR/work.1password.com"
agent setup --kind user --op-account work.1password.com > "$SB/setup.out" 2>&1
expect_eq "an unnamed re-run pointed at an account without the item fails" "$?" "1"
expect "saying the stored token could not be read" \
  grep -q "could not read stored token of identity '$USER_IDENT'" "$SB/setup.out"
expect "rather than copying the item there" test ! -e "$OP_FAKE_DIR/work.1password.com/Private"
expect_eq "and leaves the pin alone" "$(cfg identity.$USER_IDENT.opaccount)" "my.1password.com"

# A second identity for an app reuses the first one's key, which is wherever
# that identity reads from -- not in the account the new one is being pinned to.
new_sandbox
export OP_ARGV_LOG="$SB/op-argv.log"
run_setup --store op --pem "$SB/key.pem" >/dev/null 2>&1
mkdir -p "$OP_FAKE_DIR/work.1password.com"
: > "$OP_ARGV_LOG"
agent setup --name second --owner patricktulskie --app-id 1111 --store op --vault agents \
  --op-account work.1password.com >/dev/null 2>&1
expect_eq "a new identity in another account can reuse a key pinned elsewhere" "$?" "0"
expect "reading it through the account the key's identity is pinned to" \
  grep -qx -- "--account my.1password.com read op://Private/$APP_IDENT/private_key" "$OP_ARGV_LOG"
expect_fail "and never through the new one" \
  grep -q -- "--account work.1password.com read op://Private/$APP_IDENT" "$OP_ARGV_LOG"
expect "its own item lands in the account it asked for" \
  cmp -s "$OP_FAKE_DIR/work.1password.com/agents/$APP_IDENT/private_key" "$OP_FAKE_DIR/Private/$APP_IDENT/private_key"
expect_eq "which it is pinned to" "$(cfg identity.second.opaccount)" "work.1password.com"
expect_eq "while the first keeps its own pin" "$(cfg identity.$APP_IDENT.opaccount)" "my.1password.com"
expect "and its item where it was" test ! -e "$OP_FAKE_DIR/work.1password.com/Private"
OP_FAKE_DEFAULT=other.1password.com agent doctor --name second >/dev/null 2>&1
expect_eq "and the new identity reads through its pin" "$?" "0"
unset OP_ARGV_LOG

# The same item path in another account is not the item the key came from.
new_sandbox
run_setup --store op --pem "$SB/key.pem" >/dev/null 2>&1
mkdir -p "$OP_FAKE_DIR/work.1password.com"
agent setup --name second --owner patricktulskie --app-id 1111 --store op \
  --op-account work.1password.com >/dev/null 2>&1
expect_eq "a second identity in another account, same vault, exits 0" "$?" "0"
expect "writes the key to that path in its own account rather than calling it stored" \
  cmp -s "$OP_FAKE_DIR/work.1password.com/Private/$APP_IDENT/private_key" "$OP_FAKE_DIR/Private/$APP_IDENT/private_key"
expect_eq "and is pinned there" "$(cfg identity.second.opaccount)" "work.1password.com"
OP_FAKE_DEFAULT=other.1password.com agent doctor --name second >/dev/null 2>&1
expect_eq "so it reads" "$?" "0"

# --- user identity guardrails ------------------------------------------------
echo "user identity guardrails:"
new_sandbox
new_token_file "$SB/pat.txt"
run_setup_user --store file --token-file "$SB/pat.txt" >/dev/null 2>&1
printf 'github_pat_other\n' > "$SB/pat2.txt"
FAKE_GH_LOGIN=patrick-agent "$ROOT/bin/guise" setup --kind user --name mine \
  --token-file "$SB/pat2.txt" </dev/null >/dev/null 2>&1
expect_eq "refuses a token for your own account" "$?" "1"
expect "refused setup leaves the token file alone" test -f "$SB/pat2.txt"
"$ROOT/bin/guise" setup --kind user --name mine --login someone-else \
  --token-file "$SB/pat2.txt" </dev/null >/dev/null 2>&1
expect_eq "refuses a token that isn't the --login account" "$?" "1"
"$ROOT/bin/guise" setup --kind user --name mine --app-id 1111 </dev/null >/dev/null 2>&1
expect_eq "rejects app-only flags on a user identity" "$?" "1"
git config -f "$HOME/.config/guise/config" identity.$USER_IDENT.tokenexpires "2000-01-01 00:00:00 UTC"
"$ROOT/bin/guise" doctor --name "$USER_IDENT" > "$SB/doctor.out" 2>&1
expect_eq "doctor fails on a PAT inside its last 30 days" "$?" "1"
expect "on the expiry check" grep -q "FAIL  token not expiring within 30 days" "$SB/doctor.out"

