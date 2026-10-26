# --- identity naming + configurable default ----------------------------------
echo "identity naming and default:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "identity is named after the app slug" "$(cfg identity.test-agent.slug)" "test-agent"
expect "directory is named after the agent" test -d "$HOME/agentic-code/test-agent"
expect "no 'default' directory is created" test ! -e "$HOME/agentic-code/default"
expect_eq "first identity becomes the default" "$(cfg core.defaultidentity)" "test-agent"
expect_eq "'default' subcommand reports it" "$("$GUISE" default)" "test-agent"
expect_eq "token with no identity resolves the default" \
  "$("$HOME/.local/bin/guise-token")" "$("$HOME/.local/bin/guise-token" test-agent)"

openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store file --name explicit --pem "$SB/key2.pem" >/dev/null 2>&1
expect "--name still wins over the derived name" test -d "$HOME/agentic-code/explicit"
expect_eq "a later identity does not steal the default" "$(cfg core.defaultidentity)" "test-agent"
"$GUISE" default explicit >/dev/null 2>&1
expect_eq "default can be repointed" "$(cfg core.defaultidentity)" "explicit"
openssl genrsa -out "$SB/key3.pem" 2048 2>/dev/null
run_setup --store file --name claimed --pem "$SB/key3.pem" --default >/dev/null 2>&1
expect_eq "--default claims the default identity" "$(cfg core.defaultidentity)" "claimed"
"$GUISE" default nonesuch >/dev/null 2>&1
expect_eq "default rejects an unknown identity" "$?" "1"

# The config file is plain text, so the default can still end up naming nothing;
# with three identities there is no lone one to fall back on.
git config -f "$HOME/.config/guise/config" core.defaultidentity nonesuch
agent doctor > "$SB/doctor.out" 2>&1
expect_eq "doctor fails when the default names a missing identity" "$?" "1"
expect "the failure names the default check" \
  grep -q "FAIL  default identity is in config" "$SB/doctor.out"
expect "and its hint names the identities to pick from" \
  grep -q "hint: 'nonesuch' is no longer an identity -- pick one with 'guise default <name>' (have: claimed explicit test-agent )" "$SB/doctor.out"
agent default claimed >/dev/null 2>&1
agent doctor >/dev/null 2>&1
expect_eq "doctor passes once the default is repointed" "$?" "0"

# --- rename -------------------------------------------------------------------
echo "rename:"
"$GUISE" default test-agent >/dev/null 2>&1
mkdir -p "$HOME/agentic-code/test-agent/someclone"
"$GUISE" rename test-agent renamed >/dev/null 2>&1
expect_eq "rename exits 0" "$?" "0"
expect "clones move with the identity" test -d "$HOME/agentic-code/renamed/someclone"
expect "old directory is gone" test ! -e "$HOME/agentic-code/test-agent"
expect_eq "config section renamed" "$(cfg identity.renamed.slug)" "test-agent"
expect_eq "old config section gone" "$(cfg identity.test-agent.slug 2>/dev/null)" ""
expect "key file renamed" test -f "$HOME/.config/guise/keys/renamed.pem"
expect_eq "keyfile path updated" \
  "$(cfg identity.renamed.keyfile)" "$HOME/.config/guise/keys/renamed.pem"
expect "rendered conf renamed" test -f "$HOME/.config/guise/git/renamed.conf"
expect "old rendered conf gone" test ! -e "$HOME/.config/guise/git/test-agent.conf"
expect_eq "default follows the rename" "$(cfg core.defaultidentity)" "renamed"
git init -q "$HOME/agentic-code/renamed/newrepo"
expect_eq "identity applies under the new directory" \
  "$(git -C "$HOME/agentic-code/renamed/newrepo" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"
"$GUISE" doctor >/dev/null 2>&1
expect_eq "doctor passes after rename" "$?" "0"
"$GUISE" rename renamed explicit >/dev/null 2>&1
expect_eq "rename refuses a name already in use" "$?" "1"
"$GUISE" rename nonesuch whatever >/dev/null 2>&1
expect_eq "rename refuses an unknown identity" "$?" "1"

agent basedir "$HOME/agentic-code/renamed/nested" --name claimed >/dev/null 2>&1
"$GUISE" rename renamed outer >/dev/null 2>&1
expect_eq "rename refuses to move a directory another identity lives inside" "$?" "1"
expect "leaving that identity where its scope is" test -d "$HOME/agentic-code/renamed/nested/claimed"
expect_eq "and the outer one under its old name" "$(cfg identity.renamed.slug)" "test-agent"
