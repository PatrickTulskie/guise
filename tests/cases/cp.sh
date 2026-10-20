# --- cp -------------------------------------------------------------------------
# A second workspace committing as an identity that is already set up: same
# account, same credential, without reading the secret again or putting another
# signing key through the browser.
echo "cp:"
new_sandbox
run_setup --store op --pem "$SB/key.pem" >/dev/null 2>&1
new_token_file "$SB/pat.txt"
run_setup_user --store file --sign --token-file "$SB/pat.txt" >/dev/null 2>&1
keys="$HOME/.config/guise/keys"
awk '{print $1" "$2}' "$keys/$USER_IDENT.signing.pub" >> "$SIGNING_KEYS_FILE"
agent basedir "$HOME/special" --name "$USER_IDENT" >/dev/null 2>&1
user_dir="$HOME/special/$USER_IDENT"
cp_snap() { cat "$HOME/.config/guise/config" "$HOME/.config/guise/gitconfig" | shasum; }
gh_token_in() { (cd "$1" && "$HOME/.local/bin/guise-gh" echo-token); }
before=$(cp_snap)

expect_fail "cp refuses an unknown source" agent cp nonesuch scratch
expect_fail "a name already in use" agent cp "$USER_IDENT" "$APP_IDENT"
expect_fail "a name setup would refuse" agent cp "$USER_IDENT" "sc/ratch"
mkdir -p "$HOME/special/taken"
expect_fail "a directory that already exists" agent cp "$USER_IDENT" taken
if perms_enforced; then
  chmod 000 "$keys/$USER_IDENT.token"
  expect_fail "and a secret it can't read" agent cp "$USER_IDENT" scratch
  chmod 600 "$keys/$USER_IDENT.token"
else
  skip "and a secret it can't read (modes are not enforced here)"
fi
expect_eq "none of which changed the config" "$(cp_snap)" "$before"
expect "or left a copy behind to block a retry" \
  test ! -e "$keys/scratch.token" -a ! -e "$keys/scratch.signing" -a ! -e "$HOME/special/scratch"

agent cp "$USER_IDENT" scratch > "$SB/cp.out" 2>&1
expect_eq "cp exits 0" "$?" "0"
expect_eq "the copy is the same account" "$(cfg identity.scratch.login)" "$FAKE_LOGIN"
expect_eq "in the source's own workspace" "$(cfg identity.scratch.basedir)" "$HOME/special"
expect "so its directory sits beside the source" test -d "$HOME/special/scratch"
expect_eq "the token file is a copy of its own" "$(cfg identity.scratch.tokenfile)" "$keys/scratch.token"
expect_mode "at mode 600" "$keys/scratch.token" "600"
expect "holding the same token" cmp -s "$keys/scratch.token" "$keys/$USER_IDENT.token"
expect "the signing key is copied, not generated" \
  cmp -s "$keys/scratch.signing.pub" "$keys/$USER_IDENT.signing.pub"
expect_mode "its private half at mode 600" "$keys/scratch.signing" "600"
expect_eq "and the config points at the copy" "$(cfg identity.scratch.signingkey)" "$keys/scratch.signing"
expect_eq "the default does not move" "$(cfg core.defaultidentity)" "$APP_IDENT"
expect "cp says how to clone into the copy" \
  grep -q "guise clone <owner/repo> --name scratch" "$SB/cp.out"
git init -q "$user_dir/repo"
git init -q "$HOME/special/scratch/repo"
expect_eq "both directories commit as the account" \
  "$(git -C "$user_dir/repo" config --get user.email):$(git -C "$HOME/special/scratch/repo" config --get user.email)" \
  "4444+$FAKE_LOGIN@users.noreply.github.com:4444+$FAKE_LOGIN@users.noreply.github.com"
expect_eq "and guise-gh hands out the same token in each" \
  "$(gh_token_in "$user_dir"):$(gh_token_in "$HOME/special/scratch")" "github_pat_stub123:github_pat_stub123"
( cd "$HOME/special/scratch/repo" && echo x > f && git add f && git commit -q -m "signed" )
expect_eq "commits in the copy verify with the copied key" \
  "$(git -C "$HOME/special/scratch/repo" log -1 --format='%G?')" "G"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes for source and copy" "$?" "0"
expect_eq "list shows both rows with the same account" \
  "$(agent list | grep -c "@$FAKE_LOGIN")" "2"

agent cp "$APP_IDENT" scratch-bot >/dev/null 2>&1
expect_eq "a 1Password-backed copy exits 0" "$?" "0"
expect_eq "sharing the item" "$(cfg identity.scratch-bot.opitem)" "$(cfg identity.$APP_IDENT.opitem)"
expect_eq "and the account it is pinned to" "$(cfg identity.scratch-bot.opaccount)" "my.1password.com"
expect "with no key file of its own" test ! -e "$keys/scratch-bot.pem"
expect "under the shared workspace, like its source" test -d "$HOME/agentic-code/scratch-bot"
t=$("$HOME/.local/bin/guise-token" scratch-bot)
expect_eq "a token mints for it" "${t:0:4}" "ghs_"

agent rename scratch scratch2 >/dev/null 2>&1
expect_eq "the copy renames" "$?" "0"
expect "taking its own files along" \
  test -f "$keys/scratch2.token" -a -f "$keys/scratch2.signing" -a -f "$keys/scratch2.signing.pub"
expect "and none of the source's" \
  test -f "$keys/$USER_IDENT.token" -a -f "$keys/$USER_IDENT.signing" -a ! -e "$keys/scratch.token"
agent rm scratch2 --secret --signing-key >/dev/null 2>&1
expect_eq "rm shreds the copy's files" "$?" "0"
expect "and only those" \
  test ! -e "$keys/scratch2.token" -a ! -e "$keys/scratch2.signing" -a -f "$keys/$USER_IDENT.token" -a -f "$keys/$USER_IDENT.signing"
agent rm scratch-bot --force >/dev/null 2>&1
expect "removing the 1Password-backed copy leaves the shared item" \
  test -f "$OP_FAKE_DIR/Private/test-agent/private_key"
expect_eq "so the source still works" "$(gh_token_in "$user_dir")" "github_pat_stub123"
t=$("$HOME/.local/bin/guise-token" "$APP_IDENT")
expect_eq "and still mints" "${t:0:4}" "ghs_"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes with the copies gone" "$?" "0"

