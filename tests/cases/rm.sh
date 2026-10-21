# --- rm -------------------------------------------------------------------------
echo "rm:"
new_sandbox
run_setup --store op --pem "$SB/key.pem" >/dev/null 2>&1
new_token_file "$SB/pat.txt"
run_setup_user --store file --sign --token-file "$SB/pat.txt" >/dev/null 2>&1
keys="$HOME/.config/guise/keys"
app_dir="$HOME/agentic-code/$APP_IDENT"
user_dir="$HOME/agentic-code/$USER_IDENT"
# Everything pushed except one commit on a detached HEAD, which no branch names.
git init -q --bare "$SB/remote.git"
git clone -q "$SB/remote.git" "$user_dir/someclone" 2>/dev/null
git -C "$user_dir/someclone" commit -q --allow-empty -m pushed
git -C "$user_dir/someclone" push -q origin HEAD 2>/dev/null
git -C "$user_dir/someclone" checkout -q --detach
git -C "$user_dir/someclone" commit -q --allow-empty -m unpushed
rm_snap() { cat "$HOME/.config/guise/config" "$HOME/.config/guise/gitconfig" | digest; }
before=$(rm_snap)

expect_fail "a bare rm with no terminal refuses rather than guessing" agent rm "$USER_IDENT"
expect_fail "--keep contradicts the flags that delete" agent rm "$USER_IDENT" --keep --code
expect_fail "rm refuses an unknown identity" agent rm nonesuch --force
git config -f "$HOME/.config/guise/config" "identity.$USER_IDENT.basedir" "$app_dir"
expect_fail "--code refuses a directory another identity lives in" agent rm "$APP_IDENT" --code
ln -s "$app_dir" "$SB/alias"
git config -f "$HOME/.config/guise/config" "identity.$USER_IDENT.basedir" "$SB/alias"
expect_fail "or reaches through a symlink" agent rm "$APP_IDENT" --code
git config -f "$HOME/.config/guise/config" --unset "identity.$USER_IDENT.basedir"
printf 'n\nn\nn\nn\n' | "$GUISE" rm "$USER_IDENT" --wizard > "$SB/rm.declined" 2>&1
expect_eq "declining the wizard's last question exits 1" "$?" "1"
expect "after warning about a commit only a detached HEAD holds" \
  grep -q "isn't pushed anywhere" "$SB/rm.declined"
expect_eq "and none of those changed anything" "$(rm_snap)" "$before"
expect "or deleted anything" test -d "$app_dir" -a -d "$user_dir/someclone"

# The wizard only answers the flags: keep the clones and the signing key, shred
# the token. In a workspace of its own, so its root goes when the identity does.
agent basedir "$HOME/special" --name "$USER_IDENT" >/dev/null 2>&1
user_dir="$HOME/special/$USER_IDENT"
printf 'n\ny\nn\ny\n' | "$GUISE" rm "$USER_IDENT" --wizard >/dev/null 2>&1
expect_eq "the wizard removes an identity" "$?" "0"
expect_eq "its config section is gone" "$(cfg "identity.$USER_IDENT.login" 2>/dev/null)" ""
expect "its rendered conf is gone" test ! -e "$HOME/.config/guise/git/$USER_IDENT.conf"
expect "the token it was told to shred is gone" test ! -e "$keys/$USER_IDENT.token"
expect "the signing key it was told to keep stays" test -f "$keys/$USER_IDENT.signing"
expect "and so do the clones" test -d "$user_dir/someclone"
expect_eq "which are no longer in any identity's scope" \
  "$(git -C "$user_dir/someclone" config --get user.email)" "human@example.com"
agent doctor > "$SB/rm.doctor" 2>&1
expect "doctor still finds them" grep -q "$user_dir/someclone" "$SB/rm.doctor"
user_dir="$HOME/agentic-code/$USER_IDENT"
git init -q "$app_dir/repo"
expect_eq "the other identity still applies in its directory" \
  "$(git -C "$app_dir/repo" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"

new_token_file "$SB/pat.txt"
run_setup_user --store file --sign --token-file "$SB/pat.txt" >/dev/null 2>&1
git clone -q "$SB/remote.git" "$user_dir/pushed" 2>/dev/null
git clone -q "$SB/remote.git" "$user_dir/unpushed" 2>/dev/null
git -C "$user_dir/unpushed" commit -q --allow-empty -m unpushed
agent rm "$USER_IDENT" --force > "$SB/rm.out" 2>&1
expect_eq "rm --force exits 0" "$?" "0"
expect "naming the clone whose work it deleted unpushed" \
  grep -q "^  $user_dir/unpushed\$" "$SB/rm.out"
expect "and not the one that was pushed" \
  test "$(grep -c "$user_dir/pushed" "$SB/rm.out")" = 0
expect "--force takes the token" test ! -e "$keys/$USER_IDENT.token"
expect "both halves of the signing key" \
  test ! -e "$keys/$USER_IDENT.signing" -a ! -e "$keys/$USER_IDENT.signing.pub"
expect "and the clones" test ! -e "$user_dir"
expect_eq "so only the directory the wizard kept stays on doctor's list" \
  "$(cfg_all core.strandeddir)" "$HOME/special/$USER_IDENT"
expect "and says which public key to take off the account" grep -q "ssh-ed25519 " "$SB/rm.out"

# Picked from the wizard's menu this time. It is the default, and its secret is
# in 1Password, which is not guise's to delete.
new_token_file "$SB/pat.txt"
run_setup_user --store file --token-file "$SB/pat.txt" >/dev/null 2>&1
printf '%s\ny\ny\n' "$APP_IDENT" | "$GUISE" rm --wizard >/dev/null 2>&1
expect_eq "the wizard removes an identity picked from its menu" "$?" "0"
expect "deleting its directory when told to" test ! -e "$app_dir"
expect "the 1Password item is left alone" test -f "$OP_FAKE_DIR/Private/test-agent/private_key"
expect_eq "the default moves to the only identity left" "$(cfg core.defaultidentity)" "$USER_IDENT"

# --keep answers every question but the last one, so one "y" is the whole run.
printf 'y\n' | "$GUISE" rm "$USER_IDENT" --keep --wizard >/dev/null 2>&1
expect_eq "rm --keep exits 0" "$?" "0"
expect_eq "the last identity can go too" "$(cfg "identity.$USER_IDENT.login" 2>/dev/null)" ""
expect "--keep leaves the token" test -f "$keys/$USER_IDENT.token"
expect "and the directory" test -d "$user_dir"
expect "the rest of the install stays for the next setup" \
  grep -q "guise" "$HOME/.gitconfig"

# A cleanup that fails stops rm after the config section is gone, so the clones
# it strands have to be on doctor's list by then, not only at the end. The
# failure is a directory nobody may write to, which takes enforced modes.
if perms_enforced; then
  new_token_file "$SB/pat.txt"
  run_setup_user --store file --token-file "$SB/pat.txt" >/dev/null 2>&1
  agent basedir "$HOME/solo" --name "$USER_IDENT" >/dev/null 2>&1
  user_dir="$HOME/solo/$USER_IDENT"
  git init -q "$user_dir/kept"
  chmod 500 "$keys"
  expect_fail "rm --secret fails when the token can't be shredded" agent rm "$USER_IDENT" --secret
  chmod 700 "$keys"
  expect_eq "with the config section already gone" "$(cfg "identity.$USER_IDENT.login" 2>/dev/null)" ""
  agent doctor > "$SB/rm.doctor" 2>&1
  expect "and doctor still lists the clone it left behind" grep -q "$user_dir/kept" "$SB/rm.doctor"
else
  skip "rm --secret fails when the token can't be shredded (modes are not enforced here)"
fi

# A workspace deleted by hand before rm is nothing to scan, not a reason to stop.
new_token_file "$SB/pat.txt"
run_setup_user --store file --token-file "$SB/pat.txt" >/dev/null 2>&1
rm -rf "$HOME/agentic-code/$USER_IDENT"
stranded_before=$(cfg_all core.strandeddir)
agent rm "$USER_IDENT" --force > "$SB/rm.gone" 2>&1
expect_eq "rm --force removes an identity whose directory is already gone" "$?" "0"
expect_eq "config section and all" "$(cfg "identity.$USER_IDENT.login" 2>/dev/null)" ""
expect "taking the token with it" test ! -e "$keys/$USER_IDENT.token"
expect_eq "without adding the missing directory to doctor's list" \
  "$(cfg_all core.strandeddir)" "$stranded_before"

