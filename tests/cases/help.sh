# --- help is inert --------------------------------------------------------------
# The usage text is an unquoted heredoc, so anything expandable in it runs when
# help does -- a backtick once turned `guise help` into a `guise setup`. Nothing
# on stderr is the cheap way to hold that line whatever gets added to the text.
echo "help:"
new_sandbox
help_err=$("$ROOT/bin/guise" help 2>&1 >/dev/null </dev/null)
expect_eq "help writes nothing to stderr" "$help_err" ""
expect_eq "help exits 0" "$?" "0"
expect "help still lists the commands" \
  bash -c "'$ROOT/bin/guise' help 2>/dev/null | grep -q '^  setup'"
expect "and help provisions nothing" test ! -e "$HOME/.config/guise/config"

