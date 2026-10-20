# --- symlinked rc and gitconfig ------------------------------------------------
# Dotfiles are usually symlinks into a dotfiles repo. Editing the link instead of
# its target both breaks the link and leaves the block in the file the shell
# really reads, so assert on the target and on the link surviving.
echo "symlinked dotfiles:"
new_sandbox
mkdir -p "$HOME/dotfiles"
printf 'alias ll="ls -l"\n' > "$HOME/dotfiles/zshrc"
cp "$HOME/.gitconfig" "$HOME/dotfiles/gitconfig"
cp "$HOME/dotfiles/zshrc" "$SB/zshrc.pre"
cp "$HOME/dotfiles/gitconfig" "$SB/gitconfig.pre"
chmod 640 "$HOME/dotfiles/zshrc"
rm -f "$HOME/.zshrc" "$HOME/.gitconfig"
ln -s "$HOME/dotfiles/zshrc" "$HOME/.zshrc"
ln -s "$HOME/dotfiles/gitconfig" "$HOME/.gitconfig"
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
expect "setup leaves ~/.zshrc a symlink" test -L "$HOME/.zshrc"
expect "setup leaves ~/.gitconfig a symlink" test -L "$HOME/.gitconfig"
expect_eq "the rc block lands in the file the link points at" \
  "$(grep -cF '# >>> guise >>>' "$HOME/dotfiles/zshrc")" "1"
expect_eq "and the gitconfig block does too" \
  "$(grep -cF '# >>> guise >>>' "$HOME/dotfiles/gitconfig")" "1"
expect_mode "the target's mode is untouched" "$HOME/dotfiles/zshrc" "640"

# The replace path, which only runs when a block is already there and differs.
# It spans lines, and `awk -v` cannot carry a newline -- BWK awk on macOS errors
# out -- so a stale block has to survive a re-run.
printf 'alias ll="ls -l"\n\n# >>> guise >>>\nstale\n# <<< guise <<<\n' \
  > "$HOME/dotfiles/zshrc"
run_setup --store file > "$SB/replace.out" 2>&1
expect_eq "re-running setup over a stale block exits 0" "$?" "0"
expect_eq "the stale block is replaced, not duplicated" \
  "$(grep -cF '# >>> guise >>>' "$HOME/dotfiles/zshrc")" "1"
expect "and the replacement is the real source line" \
  grep -qF 'hook.sh' "$HOME/dotfiles/zshrc"
expect "through the symlink, which is still a symlink" test -L "$HOME/.zshrc"

"$ROOT/bin/guise" uninstall --yes >/dev/null 2>&1
expect "uninstall leaves ~/.zshrc a symlink" test -L "$HOME/.zshrc"
expect "uninstall leaves ~/.gitconfig a symlink" test -L "$HOME/.gitconfig"
expect "rc target byte-identical to pre-setup" \
  cmp -s "$HOME/dotfiles/zshrc" "$SB/zshrc.pre"
expect "gitconfig target byte-identical to pre-setup" \
  cmp -s "$HOME/dotfiles/gitconfig" "$SB/gitconfig.pre"

