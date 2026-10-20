# --- guided setup --------------------------------------------------------------
# The wizard reads its answers from stdin whether or not that is a terminal, so
# the suite walks the same prompts a human does. Answers are positional, and
# each block below lists them in order.
echo "guided setup:"

# kind, app-exists, owner, app id, where the key is, pem, browser pause, store,
# name, workspace, go
wizard() { "$ROOT/bin/guise" setup --wizard; }

new_sandbox
printf 'app\ny\npatricktulskie\n1111\n\n%s\nok\nfile\n\n\ny\n' "$SB/key.pem" \
  | wizard >/dev/null 2>&1
expect_eq "a guided app setup exits 0" "$?" "0"
# The whole design claim: the wizard only fills in flags, so it has to land the
# byte-identical config a flag-driven setup would.
expect_eq "app metadata still discovered from the API" "$(cfg identity.$APP_IDENT.slug)" "test-agent"
expect_eq "installation id discovered" "$(cfg identity.$APP_IDENT.installationid)" "2222"
expect_eq "the store chosen at the prompt is honoured" \
  "$(cfg identity.$APP_IDENT.keysource)" "file"
expect "the PEM is shredded like any other" test ! -e "$SB/key.pem"
expect "identity dir created" test -d "$HOME/agentic-code/$APP_IDENT"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes on a guided install" "$?" "0"

# A second app identity: the stored key is offered rather than asked for, so
# there is no pem answer here -- reuse, browser pause, store, name, ...
printf 'new\napp\ny\npatricktulskie\n1111\ny\nok\nfile\nsecond\n\nn\ny\n' \
  | wizard >/dev/null 2>&1
expect_eq "a second identity for the same app exits 0" "$?" "0"
expect "and reuses the stored key without asking for a PEM" test -d "$HOME/agentic-code/second"
expect_eq "without stealing the default" "$(cfg core.defaultidentity)" "$APP_IDENT"
printf 'new\napp\ny\npatricktulskie\n1111\ny\nok\n\nthird\n\n\ny\n' \
  | wizard >/dev/null 2>&1
expect_eq "unless asked to, which is what enter does" "$(cfg core.defaultidentity)" "third"

# A name and a workspace typed at the prompts, rather than derived.
new_sandbox
printf 'app\ny\npatricktulskie\n1111\n\n%s\nok\nfile\nchosen\n%s\ny\n' \
  "$SB/key.pem" "$HOME/elsewhere" | wizard >/dev/null 2>&1
expect "an answered name becomes the identity" test -d "$HOME/elsewhere/chosen"
expect_eq "and an answered workspace becomes the basedir" "$(cfg core.basedir)" "$HOME/elsewhere"

# Declining at the summary has to leave no trace -- the whole point of asking
# before doing anything.
new_sandbox
printf 'app\ny\npatricktulskie\n1111\n\n%s\nok\nfile\n\n\nn\n' "$SB/key.pem" \
  | wizard >/dev/null 2>&1
expect_eq "declining at the summary fails" "$?" "1"
expect "and writes no config" test ! -e "$HOME/.config/guise/config"
expect "and leaves the PEM alone" test -f "$SB/key.pem"

# Anything checkable without the network is re-asked, not fatal: a bad choice,
# a non-numeric app id, and a path with no key at it. A menu also takes the
# number of its choice.
printf 'maybe\n2\ny\npatricktulskie\nnotanumber\n1111\n\n/nonesuch.pem\n%s\nok\nfile\n\n\ny\n' \
  "$SB/key.pem" | wizard >/dev/null 2>&1
expect_eq "a bad choice, app id, and PEM path are all re-asked" "$?" "0"
expect_eq "and the run still completes correctly" "$(cfg identity.$APP_IDENT.installationid)" "2222"

# kind, account-exists, login, where the token is, browser pause, token, sign,
# store, name, workspace, go, signing-key browser pause, check again or skip
new_sandbox
printf 'user\ny\npatrick-agent\n\nok\ngithub_pat_wizard\n\n\n\n\ny\nok\nskip\n' \
  | wizard >/dev/null 2>&1
# Non-zero, and correctly so: the key was skipped rather than added to the
# account, so doctor still reports the one gap setup can't close.
expect_eq "a guided account setup ends on the one gap it can't close" "$?" "1"
expect_eq "kind recorded" "$(cfg identity.$USER_IDENT.kind)" "user"
expect_eq "user id discovered from the API" "$(cfg identity.$USER_IDENT.userid)" "4444"
# Typed at the prompt, carried in the process, stored once: never in argv and
# never in a file of its own on the way there.
expect_eq "the pasted token is what got stored" \
  "$(cat "$HOME/.config/guise/keys/$USER_IDENT.token")" "github_pat_wizard"
expect_eq "and kept in a file unless told otherwise" "$(cfg identity.$USER_IDENT.keysource)" "file"
expect_eq "signing is on unless declined" "$(cfg identity.$USER_IDENT.signing)" "ssh"
expect "signing key generated" test -f "$HOME/.config/guise/keys/$USER_IDENT.signing"
printf '%s\n' "$(awk '{print $1" "$2}' "$HOME/.config/guise/keys/$USER_IDENT.signing.pub")" \
  >> "$SIGNING_KEYS_FILE"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes on a guided account install" "$?" "0"

# Picking an existing identity walks its settings with what it has now as every
# default: new token, signing, store, then the summary. Enter all the way through
# is a plain re-run, and the answers that do change are the only changes.
snap_guided=$(snapshot)
printf '%s\n\n\n\n\n' "$USER_IDENT" | wizard >/dev/null 2>&1
expect_eq "reviewing an existing identity through the wizard exits 0" "$?" "0"
expect_eq "and entering through every answer changes nothing" "$(snapshot)" "$snap_guided"
printf '%s\ny\nok\ngithub_pat_rotated\nn\n\n\n' "$USER_IDENT" | wizard >/dev/null 2>&1
expect_eq "a changed answer exits 0" "$?" "0"
expect_eq "a new token pasted during review is stored" \
  "$(cat "$HOME/.config/guise/keys/$USER_IDENT.token")" "github_pat_rotated"
expect_fail "and signing declined during review turns off" cfg identity.$USER_IDENT.signing
expect_eq "while the store it didn't touch stays put" "$(cfg identity.$USER_IDENT.keysource)" "file"

# The same review, but for an app identity: owner, App ID, new key, store,
# summary.
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
printf 'y\nok\n\n\ny\n' | "$ROOT/bin/guise" setup --wizard \
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
  | "$ROOT/bin/guise" setup --wizard --op-account work.1password.com >/dev/null 2>&1
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

# A dumb terminal is still a terminal, so a bare setup runs the wizard -- but
# nothing it draws may need the cursor moved to take it back.
new_sandbox
if have_pty; then
  printf 'app\ny\npatricktulskie\n1111\n\n%s\nok\n\n\n\nn\n' "$SB/key.pem" \
    | TERM=dumb in_pty "'$ROOT/bin/guise' setup" > "$SB/dumb.out" 2>&1
  grep -q "Look good?" "$SB/dumb.out" || sed 's/^/    | /' "$SB/dumb.out"
  expect "a bare setup on a dumb terminal still runs the wizard" \
    grep -q "Look good?" "$SB/dumb.out"
  expect_fail "without a single escape sequence" grep -q $'\033' "$SB/dumb.out"
else
  skip "a bare setup on a dumb terminal still runs the wizard (no script, so no pty)"
fi

# The wizard is what a bare setup does *on a terminal*. With no terminal there
# is nothing to ask, so the flag-driven refusal stands.
new_sandbox
expect_fail "a bare setup with no terminal still refuses rather than prompting" agent setup
expect "and writes no config" test ! -e "$HOME/.config/guise/config"
expect_fail "there is still no --token flag to pass" \
  agent setup --kind user --token github_pat_nope

