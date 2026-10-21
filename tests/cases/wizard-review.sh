# --- guided setup: reviewing an app identity, and 1Password through the prompts
# The review an app identity gets: owner, App ID, new key, store, summary.
echo "guided setup, reviewing:"
wizard() { "$GUISE" setup --wizard; }

new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
snap_app=$(snapshot)
printf '%s\n\n\n\n\n\n' "$APP_IDENT" | wizard >/dev/null 2>&1
expect_eq "reviewing an app identity through the wizard exits 0" "$?" "0"
expect_eq "offers its owner and App ID back rather than asking afresh" "$(snapshot)" "$snap_app"
agent basedir "$HOME/work" --name "$APP_IDENT" >/dev/null 2>&1
printf '%s\n\n\n\n\n\n' "$APP_IDENT" | wizard >/dev/null 2>&1
expect "a review leaves a moved workspace where it is" test -d "$HOME/work/$APP_IDENT"
expect "without recreating it under the shared one" test ! -e "$HOME/agentic-code/$APP_IDENT"
expect_eq "and the app metadata is intact" "$(cfg identity.$APP_IDENT.appid)" "1111"


# Entering the human's own account is a local mistake like any other, so the
# wizard asks again instead of ending the run.
new_sandbox
export FAKE_GH_LOGIN=PatrickTulskie
printf 'user\ny\nPatrickTulskie\npatrick-agent\n\nok\ngithub_pat_wiz\nn\nfile\n\n\ny\n' \
  | wizard >/dev/null 2>&1
expect_eq "answering the human's own login is re-asked, not fatal" "$?" "0"
expect_eq "and the agent account is what got set up" \
  "$(cfg identity.$USER_IDENT.login)" "patrick-agent"
unset FAKE_GH_LOGIN

# --wizard alongside flags asks only for what the flags did not answer, so the
# two ways of driving setup compose instead of one overriding the other.
new_sandbox
printf 'y\nok\n\n\ny\n' | "$GUISE" setup --wizard \
  --kind app --owner patricktulskie --app-id 1111 --pem "$SB/key.pem" \
  --store file >/dev/null 2>&1
expect_eq "--wizard with flags exits 0" "$?" "0"
expect_eq "the flags are taken, not re-asked" "$(cfg identity.$APP_IDENT.appid)" "1111"
expect_eq "including the store" "$(cfg identity.$APP_IDENT.keysource)" "file"

# op-cache is on the store menu when it is installed, and picking it asks for
# the vault like 1Password does: kind, account-exists, login, where the token
# is, browser pause, token, sign, store, vault, name, workspace, go.
new_sandbox
printf 'user\ny\npatrick-agent\n\nok\ngithub_pat_wizcache\nn\nop-cache\n\n\n\ny\n' \
  | wizard >/dev/null 2>&1
expect_eq "choosing op-cache at the prompt exits 0" "$?" "0"
expect_eq "and is what got recorded" "$(cfg identity.$USER_IDENT.keysource)" "op-cache"
expect_eq "with the token in the vault it asked about" \
  "$(cat "$OP_FAKE_DIR/Private/patrick-agent/token")" "github_pat_wizcache"
# Reviewing it offers op-cache back as the default: new token, signing, store,
# vault, summary.
snap_cache=$(snapshot)
printf '%s\n\n\n\n\n\n' "$USER_IDENT" | wizard >/dev/null 2>&1
expect_eq "reviewing an op-cache identity exits 0" "$?" "0"
expect_eq "and entering through keeps it" "$(snapshot)" "$snap_cache"
# An --op-account alongside the review names where the item is now, over the
# account the identity was pinned to: new token, signing, store, vault, summary.
mkdir -p "$OP_FAKE_DIR/work.1password.com/Private"
cp -R "$OP_FAKE_DIR/Private/$USER_IDENT" "$OP_FAKE_DIR/work.1password.com/Private/"
printf '%s\n\n\n\n\n\n' "$USER_IDENT" \
  | "$GUISE" setup --wizard --op-account work.1password.com >/dev/null 2>&1
expect_eq "reviewing with --op-account exits 0" "$?" "0"
expect_eq "and re-pins the identity to that account" \
  "$(cfg identity.$USER_IDENT.opaccount)" "work.1password.com"
op-cache clear >/dev/null
expect_eq "which is where it reads from" \
  "$(OP_FAKE_DEFAULT=other.1password.com "$HOME/.local/bin/guise-token" "$USER_IDENT")" "github_pat_wizcache"

# A token already in 1Password is pointed at rather than pasted, and the
# reference is re-asked until it reads: kind, account-exists, login, where the
# token is, item (twice wrong), sign, store, name, workspace, go.
new_sandbox
mkdir -p "$OP_FAKE_DIR/agents/Held"
printf 'github_pat_held' > "$OP_FAKE_DIR/agents/Held/token"
printf 'user\ny\npatrick-agent\nop\nnope\nop://agents/Missing\nop://agents/Held\nn\n\n\n\ny\n' \
  | wizard >/dev/null 2>&1
expect_eq "pointing the wizard at a 1Password item exits 0" "$?" "0"
expect_eq "and the identity reads from it" "$(cfg identity.$USER_IDENT.opitem)" "op://agents/Held"
expect_eq "kept in 1Password, since a file isn't on offer" "$(cfg identity.$USER_IDENT.keysource)" "op"
# Reviewing it once the item has moved says so and asks where it went: new
# token, signing, where it is now, item, store, go.
mv "$OP_FAKE_DIR/agents/Held" "$OP_FAKE_DIR/agents/Moved"
printf '%s\n\n\n\nop://agents/Moved\n\n\n' "$USER_IDENT" | wizard >/dev/null 2>&1
expect_eq "reviewing an identity whose item moved exits 0" "$?" "0"
expect_eq "pointing it at the item's new home" "$(cfg identity.$USER_IDENT.opitem)" "op://agents/Moved"
