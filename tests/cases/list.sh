# --- list -----------------------------------------------------------------------
# One row per identity, carrying what you'd otherwise open the config file for:
# which account it commits as, where its secret lives, where its clones go.
echo "list:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
printf 'github_pat_listed\n' > "$SB/pat.txt"
run_setup_user --store op --token-file "$SB/pat.txt" >/dev/null 2>&1
agent list > "$SB/list.out" 2>&1
expect_eq "list exits 0" "$?" "0"
expect_eq "the bot's row, starred because it is the default" \
  "$(grep "$APP_IDENT" "$SB/list.out" | tr -s ' ')" \
  "* $APP_IDENT app test-agent[bot] on patricktulskie file ~/agentic-code/$APP_IDENT"
expect_eq "the account's row, unstarred and reading from 1Password" \
  "$(grep "$USER_IDENT" "$SB/list.out" | tr -s ' ')" \
  " $USER_IDENT user @$FAKE_LOGIN op ~/agentic-code/$USER_IDENT"
expect_fail "and no secret anywhere near it" grep -q github_pat_listed "$SB/list.out"
agent basedir "$HOME/src" --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "an identity with a workspace of its own shows that one" \
  "$(agent list | grep "$USER_IDENT" | tr -s ' ')" \
  " $USER_IDENT user @$FAKE_LOGIN op ~/src/$USER_IDENT"
agent default "$USER_IDENT" >/dev/null 2>&1
expect_eq "the star follows the default" \
  "$(agent list | sed -n 's/^\* \([^ ]*\) .*/\1/p')" "$USER_IDENT"
expect_fail "list takes no arguments" agent list "$APP_IDENT"

# The star names what a command with nothing to go on would land on, which is
# not always what the config records -- a lone identity is the default whether
# or not anything says so, and `clone` and `use` resolve it that way.
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
git config -f "$HOME/.config/guise/config" --unset core.defaultidentity
expect_eq "with no default recorded, the only identity is still starred" \
  "$(agent list | sed -n 's/^\* \([^ ]*\) .*/\1/p')" "$APP_IDENT"
openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store file --name second --pem "$SB/key2.pem" >/dev/null 2>&1
git config -f "$HOME/.config/guise/config" --unset core.defaultidentity
expect_eq "and nothing is starred once there is nothing to resolve" \
  "$(agent list | sed -n 's/^\* .*/starred/p')" ""

