# --- guise-gh picks the identity up from the directory --------------------------
# Two accounts with different stored tokens, so the token gh is handed says
# which identity guise-gh resolved.
echo "guise-gh identity inference:"
new_sandbox
printf 'github_pat_one\n' > "$SB/pat1"
printf 'github_pat_two\n' > "$SB/pat2"
FAKE_LOGIN=agent-one FAKE_USER_ID=4001 \
  run_setup_user --store file --token-file "$SB/pat1" >/dev/null 2>&1
FAKE_LOGIN=agent-two FAKE_USER_ID=4002 \
  run_setup_user --store file --token-file "$SB/pat2" >/dev/null 2>&1
gh_token_in() { (cd "$1" && "$HOME/.local/bin/guise-gh" echo-token); }
expect_eq "guise-gh uses the identity owning the directory" \
  "$(gh_token_in "$HOME/agentic-code/agent-two")" "github_pat_two"
expect_eq "and the default from outside the workspace" \
  "$(gh_token_in "$HOME")" "github_pat_one"
agent basedir "$HOME/elsewhere" --name agent-two >/dev/null 2>&1
expect_eq "and follows an identity to its own workspace" \
  "$(gh_token_in "$HOME/elsewhere/agent-two")" "github_pat_two"
# The helpers have always read GUISE_CONFIG. guise-gh now resolves the identity
# through `guise which`, so guise itself has to read the same config -- or the
# two disagree and gh runs as whoever the home config calls the default.
cp "$HOME/.config/guise/config" "$SB/alt-config"
git config -f "$SB/alt-config" core.basedir "$HOME/altroot"
# agent-two picked up a workspace of its own above; in this config it follows
# the shared root, which is what makes the two configs disagree about the path.
git config -f "$SB/alt-config" --unset identity.agent-two.basedir
mkdir -p "$HOME/altroot/agent-two"
expect_eq "guise-gh resolves against GUISE_CONFIG, not the home config" \
  "$(cd "$HOME/altroot/agent-two" && GUISE_CONFIG="$SB/alt-config" \
      "$HOME/.local/bin/guise-gh" echo-token)" "github_pat_two"
expect_eq "and guise which answers from it too" \
  "$(cd "$HOME/altroot/agent-two" && GUISE_CONFIG="$SB/alt-config" \
      "$GUISE" which)" "agent-two"

expect_eq "GUISE_IDENTITY still overrides the directory" \
  "$(cd "$HOME/agentic-code/agent-one" && GUISE_IDENTITY=agent-two "$HOME/.local/bin/guise-gh" echo-token)" \
  "github_pat_two"

# gh is a Go program and reads the first GH_TOKEN in its environment, so an
# inherited one has to be replaced, not shadowed. printenv shows which entry
# the child actually got: the first on BSD, every one on GNU.
mkdir -p "$SB/printenv-gh"
ln -s "$(command -v printenv)" "$SB/printenv-gh/gh"
expect_eq "guise-gh replaces an inherited GH_TOKEN rather than adding a second" \
  "$(cd "$HOME/elsewhere/agent-two" && GH_TOKEN=inherited PATH="$SB/printenv-gh:$PATH" \
      "$HOME/.local/bin/guise-gh" GH_TOKEN)" "github_pat_two"

# gh falls back to its stored login when GH_TOKEN is empty, so an unreadable
# token has to stop guise-gh before gh runs at all.
rm "$HOME/.config/guise/keys/agent-two.token"
expect_fail "guise-gh fails when the identity's token can't be read" \
  gh_token_in "$HOME/elsewhere/agent-two"
expect_eq "and never reaches gh" \
  "$(gh_token_in "$HOME/elsewhere/agent-two" 2>/dev/null || true)" ""

