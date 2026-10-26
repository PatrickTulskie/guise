# --- a $HOME with a space, an apostrophe and a # in it -------------------------
echo "spaced home:"
new_sandbox "O'Brien #1 home"
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "setup exits 0" "$?" "0"
# Git Bash leaves an argument with an apostrophe in it unconverted, so git is
# handed the path the way it would spell it itself.
repo=$(git_path "$HOME/agentic-code/$APP_IDENT/repo")
git init -q "$repo"
expect_eq "git gets the identity's credential through a helper path with a space and an apostrophe" \
  "$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 \
    git -C "$repo" credential fill 2>/dev/null | grep '^username=')" \
  "username=x-access-token"
expect_eq "the hooks path survives the config parser's comment characters" \
  "$(git -C "$repo" config --get core.hooksPath)" "$(git_path "$HOME/.config/guise/git/hooks")"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes" "$?" "0"

export FAKE_GH_LOGIN=PatrickTulskie
new_token_file "$SB/pat.txt"
run_setup_user --store file --sign --token-file "$SB/pat.txt" >/dev/null 2>&1
signrepo=$(git_path "$HOME/agentic-code/$USER_IDENT/signed")
git init -q "$signrepo"
expect_eq "the signing key path survives it too" \
  "$(git -C "$signrepo" config --get user.signingkey)" "$(git_path "$HOME/.config/guise/keys/$USER_IDENT.signing")"
( cd "$signrepo" && echo x > f && git add f && git commit -q -m "signed commit" )
expect_eq "and so does the allowed signers file a commit verifies against" \
  "$(git -C "$signrepo" log -1 --format='%G?')" "G"
