# --- uninstall restores prior state ------------------------------------------
echo "uninstall:"
new_sandbox
printf 'alias ll="ls -l"\n' > "$HOME/.zshrc"
cp "$HOME/.gitconfig" "$SB/gitconfig.pre"
cp "$HOME/.zshrc" "$SB/zshrc.pre"
run_setup --store op --pem "$SB/key.pem" >/dev/null 2>&1
"$GUISE" uninstall --yes >/dev/null 2>&1
expect_eq "uninstall exits 0" "$?" "0"
expect "~/.gitconfig byte-identical to pre-setup" cmp -s "$HOME/.gitconfig" "$SB/gitconfig.pre"
expect "~/.zshrc byte-identical to pre-setup" cmp -s "$HOME/.zshrc" "$SB/zshrc.pre"
expect "config dir removed" test ! -e "$HOME/.config/guise"
expect "token cache removed" test ! -e "$XDG_CACHE_HOME/guise"
expect "helpers removed" test ! -e "$HOME/.local/bin/guise-token"
expect "1Password item left alone" test -f "$OP_FAKE_DIR/Private/test-agent/private_key"
expect "agent dir left alone" test -d "$HOME/agentic-code/$APP_IDENT"
expect_eq "human git identity unchanged" \
  "$(git config --global user.email)" "human@example.com"

