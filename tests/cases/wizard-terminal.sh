# --- guided setup: what counts as a terminal ---------------------------------
echo "guided setup, terminals:"
# A dumb terminal is still a terminal, so a bare setup runs the wizard -- but
# nothing it draws may need the cursor moved to take it back.
new_sandbox
if have_pty; then
  printf 'app\ny\npatricktulskie\n1111\n\n%s\nok\n\n\n\nn\n' "$SB/key.pem" \
    | TERM=dumb in_pty "'$GUISE' setup" > "$SB/dumb.out" 2>&1
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
