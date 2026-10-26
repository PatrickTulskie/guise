# --- a $HOME with a space and an apostrophe in it ------------------------------
echo "spaced home:"
new_sandbox "O'Brien home"
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
agent doctor >/dev/null 2>&1
expect_eq "doctor passes" "$?" "0"
