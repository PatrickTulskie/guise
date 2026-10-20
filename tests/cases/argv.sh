# --- secrets stay out of argv ------------------------------------------------
# ps shows argv to every same-user process, and the agent is one. The op stub
# logs every argv it sees, and the curl stub refuses an Authorization header
# that didn't arrive through --config, so a leaked JWT fails every setup and
# doctor above; the 1Password write is what gets checked here.
echo "secrets stay out of argv:"
new_sandbox
export OP_ARGV_LOG="$SB/op-argv.log"
printf '%s' "$(cat "$SB/key.pem")" > "$SB/key.expected"
run_setup --store op --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "an app key into 1Password exits 0" "$?" "0"
expect "and lands byte for byte" cmp -s "$OP_FAKE_DIR/Private/$APP_IDENT/private_key" "$SB/key.expected"
expect_eq "as a concealed field" "$(cat "$OP_FAKE_DIR/Private/$APP_IDENT/.type/private_key")" "CONCEALED"
expect_fail "with no line of it in op's argv" grep -qF -f "$SB/key.expected" "$OP_ARGV_LOG"
expect "while the public fields still go in as assignments" \
  grep -qF 'app_id[text]=1111 installation_id[text]=2222' "$OP_ARGV_LOG"
t=$("$HOME/.local/bin/guise-token" "$APP_IDENT")
expect_eq "and the JWT mints a token through curl's config" "${t:0:4}" "ghs_"
printf 'github_pat_quiet\n' > "$SB/pat.txt"
run_setup_user --store op-cache --token-file "$SB/pat.txt" >/dev/null 2>&1
expect_eq "a PAT into 1Password through op-cache exits 0" "$?" "0"
expect_eq "and lands byte for byte" "$(cat "$OP_FAKE_DIR/Private/$USER_IDENT/token")" "github_pat_quiet"
expect_eq "as a concealed field" "$(cat "$OP_FAKE_DIR/Private/$USER_IDENT/.type/token")" "CONCEALED"
expect_fail "with no trace of it in op's argv" grep -qF github_pat_quiet "$OP_ARGV_LOG"

# The write is a template round trip of the whole item, which has to carry
# every other concealed field across as it was.
printf 'whsec_keep' > "$OP_FAKE_DIR/Private/$USER_IDENT/webhook_secret"
echo CONCEALED > "$OP_FAKE_DIR/Private/$USER_IDENT/.type/webhook_secret"
printf 'github_pat_rotated\n' > "$SB/pat2.txt"
run_setup_user --token-file "$SB/pat2.txt" >/dev/null 2>&1
expect_eq "rotating the token in place exits 0" "$?" "0"
expect_eq "stores the new one" "$(cat "$OP_FAKE_DIR/Private/$USER_IDENT/token")" "github_pat_rotated"
expect_eq "and leaves another concealed field on the item intact" \
  "$(cat "$OP_FAKE_DIR/Private/$USER_IDENT/webhook_secret")" "whsec_keep"

# Before 2.30 op has no --reveal, so that round trip would blank those fields:
# refuse before anything is written or shredded.
new_sandbox
printf 'github_pat_old\n' > "$SB/pat.txt"
OP_FAKE_VERSION=2.29.2 run_setup_user --store op --token-file "$SB/pat.txt" > "$SB/setup.out" 2>&1
expect_eq "an op older than 2.30 is refused" "$?" "1"
expect "naming the version it has and the one it needs" \
  grep -q "op 2.29.2 is too old.*2.30" "$SB/setup.out"
expect "with the token file not shredded" test -f "$SB/pat.txt"
expect "nothing in 1Password" test ! -e "$OP_FAKE_DIR/Private/$USER_IDENT"
expect "and no config written" test ! -e "$HOME/.config/guise/config"
unset OP_ARGV_LOG

