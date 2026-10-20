# --- stray markers -------------------------------------------------------------
# The block is found by its markers, so a file where they do not form one clean
# pair cannot be edited without guessing. Guessing here means deleting lines the
# human wrote, so refuse the file and leave it alone.
echo "stray markers:"
new_sandbox
printf 'alias ll="ls -l"\n# >>> guise >>>\nexport IMPORTANT=1\n' > "$HOME/.zshrc"
cp "$HOME/.zshrc" "$SB/zshrc.pre"
run_setup --store file --pem "$SB/key.pem" > "$SB/stray.out" 2>&1
expect_eq "setup fails on an rc with an orphan start marker" "$?" "1"
expect "and names the file to fix" \
  grep -qF "error: ~/.zshrc has a stray guise marker" "$SB/stray.out"
expect "and the lines below the orphan are still there" \
  cmp -s "$HOME/.zshrc" "$SB/zshrc.pre"

new_sandbox
printf '\n# >>> guise >>>\nstale\n# <<< guise <<<\n' >> "$HOME/.gitconfig"
printf '\n# >>> guise >>>\nstale\n# <<< guise <<<\n' >> "$HOME/.gitconfig"
cp "$HOME/.gitconfig" "$SB/gitconfig.pre"
run_setup --store file --pem "$SB/key.pem" > "$SB/dup.out" 2>&1
expect_eq "setup fails on a gitconfig carrying two blocks" "$?" "1"
expect "and leaves it untouched rather than picking one" \
  cmp -s "$HOME/.gitconfig" "$SB/gitconfig.pre"

# A line that only quotes the marker text is ordinary shell, not wiring. Marker
# discovery compares whole lines for that reason, and setup has to sail past it.
new_sandbox
printf 'echo "# >>> guise >>>"\nalias ll="ls -l"\n' > "$HOME/.zshrc"
run_setup --store file --pem "$SB/key.pem" > "$SB/quoted.out" 2>&1
expect_eq "setup ignores a line that merely quotes a marker" "$?" "0"
expect "and the line is still there afterwards" \
  grep -qxF 'echo "# >>> guise >>>"' "$HOME/.zshrc"
expect_eq "with exactly one real block added below it" \
  "$(grep -cxF '# >>> guise >>>' "$HOME/.zshrc")" "1"
"$ROOT/bin/guise" uninstall --yes >/dev/null 2>&1
expect_eq "and uninstall takes the block, not the quoted line" \
  "$(cat "$HOME/.zshrc")" "$(printf 'echo "# >>> guise >>>"\nalias ll="ls -l"')"

# Restore is byte-for-byte, which includes a file that never ended in a newline:
# awk's print would quietly add one and uninstall would hand back a longer file.
new_sandbox
printf 'alias ll="ls -l"' > "$HOME/.zshrc"
cp "$HOME/.zshrc" "$SB/zshrc.pre"
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
"$ROOT/bin/guise" uninstall --yes >/dev/null 2>&1
expect "an rc with no trailing newline comes back byte-identical" \
  cmp -s "$HOME/.zshrc" "$SB/zshrc.pre"

