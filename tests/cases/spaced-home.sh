# --- a $HOME with a space in it ------------------------------------------------
echo "spaced home:"
new_sandbox "my home"
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "setup exits 0" "$?" "0"
git init -q "$HOME/agentic-code/$APP_IDENT/repo"
expect_eq "git gets the identity's credential through a helper path with a space" \
  "$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 \
    git -C "$HOME/agentic-code/$APP_IDENT/repo" credential fill 2>/dev/null | grep '^username=')" \
  "username=x-access-token"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes" "$?" "0"
