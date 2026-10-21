# --- guided setup --------------------------------------------------------------
# The wizard reads its answers from stdin whether or not that is a terminal, so
# the suite walks the same prompts a human does. Answers are positional, and
# each block below lists them in order.
echo "guided setup:"

# kind, app-exists, owner, app id, where the key is, pem, browser pause, store,
# name, workspace, go
wizard() { "$GUISE" setup --wizard; }

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
