# --- user account identity ---------------------------------------------------
echo "user account identity:"
new_sandbox
printf 'github_pat_stub123\n' > "$SB/pat.txt"
"$ROOT/bin/guise" setup --store op --token-file "$SB/pat.txt" \
  --op-account my.1password.com </dev/null >/dev/null 2>&1
expect_eq "setup with no app flags sets up an account" "$?" "0"
expect_eq "kind recorded" "$(cfg identity.$USER_IDENT.kind)" "user"
expect_eq "login discovered from the token" "$(cfg identity.$USER_IDENT.login)" "patrick-agent"
expect_eq "user id discovered" "$(cfg identity.$USER_IDENT.userid)" "4444"
expect_eq "token expiry recorded" \
  "$(cfg identity.$USER_IDENT.tokenexpires)" "2099-01-01 00:00:00 UTC"
expect "token stored in 1Password" test -f "$OP_FAKE_DIR/Private/patrick-agent/token"
expect "token file shredded" test ! -e "$SB/pat.txt"
expect_eq "token helper returns the PAT verbatim" \
  "$("$HOME/.local/bin/guise-token" "$USER_IDENT")" "github_pat_stub123"
expect "PAT is not cached to disk" test ! -e "$XDG_CACHE_HOME/guise/$USER_IDENT.token.json"

repo="$HOME/agentic-code/$USER_IDENT/usertest"
git init -q "$repo"
expect_eq "account identity applies inside scope" \
  "$(git -C "$repo" config --get user.email)" "4444+patrick-agent@users.noreply.github.com"
expect_eq "commits are authored by the account, not a bot" \
  "$(git -C "$repo" config --get user.name)" "patrick-agent"
"$ROOT/bin/guise" doctor --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "doctor passes for a user identity" "$?" "0"

FAKE_REPO_COUNT=0 "$ROOT/bin/guise" doctor --name "$USER_IDENT" > "$SB/doctor.out" 2>&1
expect_eq "doctor fails when the PAT reaches no repos" "$?" "1"
expect "the failure names the token reachability check" \
  grep -q "FAIL  token reaches at least one repository" "$SB/doctor.out"
"$ROOT/bin/guise" doctor --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "doctor passes again once the PAT reaches a repo" "$?" "0"

# A token nobody authorized for a SAML org still lists repos from everywhere
# else, so the reachability check passes and only the response header says
# that org is missing.
FAKE_SSO=partial agent doctor --name "$USER_IDENT" > "$SB/doctor.out" 2>&1
expect_eq "doctor fails when a SAML org has not authorized the PAT" "$?" "1"
expect "the failure names the SSO check" \
  grep -q "FAIL  token authorized for every SAML SSO org" "$SB/doctor.out"
expect "and its hint points at Configure SSO" grep -q "Configure SSO" "$SB/doctor.out"
expect "while the repo reachability check still passes" \
  grep -q "ok    token reaches at least one repository" "$SB/doctor.out"
FAKE_SSO=required agent doctor --name "$USER_IDENT" > "$SB/doctor.out" 2>&1
expect "an SSO 403 fails the same check" \
  grep -q "FAIL  token authorized for every SAML SSO org" "$SB/doctor.out"

# Only minted App tokens are cached, so a cache file under a PAT identity's
# name is a copy of the standing credential that something else wrote.
mkdir -p "$XDG_CACHE_HOME/guise"
printf '{"token":"github_pat_stub123"}\n' > "$XDG_CACHE_HOME/guise/$USER_IDENT.token.json"
agent doctor --name "$USER_IDENT" > "$SB/doctor.out" 2>&1
expect_eq "doctor fails on a token cache for an account identity" "$?" "1"
expect "the failure names the cache check" \
  grep -q "FAIL  no token cache on disk for an account" "$SB/doctor.out"
expect "and its hint names the file and calls the token exposed" \
  grep -q "hint: delete $XDG_CACHE_HOME/guise/$USER_IDENT.token.json -- .*treat it as exposed" "$SB/doctor.out"
rm "$XDG_CACHE_HOME/guise/$USER_IDENT.token.json"
agent doctor --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "doctor passes once the cache file is gone" "$?" "0"

"$ROOT/bin/guise" setup --kind user </dev/null >/dev/null 2>&1
expect_eq "re-run without --token-file reuses the stored token" "$?" "0"

# App and user identities have to coexist: they share basedir and ~/.gitconfig.
run_setup --store op --name bot --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "app identity alongside a user identity" "$?" "0"
expect_eq "both identities in the owned gitconfig" \
  "$(grep -c includeIf "$HOME/.config/guise/gitconfig")" "2"
"$ROOT/bin/guise" doctor >/dev/null 2>&1
expect_eq "doctor passes with both kinds present" "$?" "0"

