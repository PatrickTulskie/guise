# --- use ----------------------------------------------------------------------
# `use` replaces itself with $SHELL, so stand a recording script in for one and
# read back where it landed.
echo "use:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store file --name platform --pem "$SB/key2.pem" >/dev/null 2>&1
cat > "$SB/recording-shell" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$PWD" > "$SB/use.pwd"
printf '%s\n' "\${GUISE_IDENTITY:-}" > "$SB/use.identity"
EOF
chmod +x "$SB/recording-shell"

SHELL="$SB/recording-shell" "$GUISE" use platform </dev/null >/dev/null 2>&1
expect_eq "use lands in the named identity's directory" \
  "$(cat "$SB/use.pwd")" "$HOME/agentic-code/platform"
# Nothing is exported: the directory is what carries the identity, so there is
# no stale variable to follow you out of the tree.
expect_eq "and exports nothing to go stale" "$(cat "$SB/use.identity")" ""

rm -f "$SB/use.pwd"
SHELL="$SB/recording-shell" "$GUISE" use </dev/null >/dev/null 2>&1
expect_eq "no name lands in the default identity's directory" \
  "$(cat "$SB/use.pwd")" "$HOME/agentic-code/$APP_IDENT"

# Retargeting the default moves where a bare `use` lands, which is what tells
# the config apart from any first-identity fallback.
rm -f "$SB/use.pwd"
agent default platform >/dev/null
SHELL="$SB/recording-shell" "$GUISE" use </dev/null >/dev/null 2>&1
expect_eq "and follows the default when it moves" \
  "$(cat "$SB/use.pwd")" "$HOME/agentic-code/platform"

# Nothing configured and more than one identity: there is no right guess.
git config -f "$HOME/.config/guise/config" --unset core.defaultidentity
rm -f "$SB/use.pwd"
expect_fail "use refuses to guess with no default and several identities" \
  env SHELL="$SB/recording-shell" "$GUISE" use
expect "and starts no shell" test ! -e "$SB/use.pwd"
agent default "$APP_IDENT" >/dev/null

expect_fail "use refuses an unknown identity" agent use nonesuch

# The shell hook: `use --emit-shell` prints the cd, the sourced function runs it
# in the shell you are already in. Everything else falls through to the script.
expect_eq "--emit-shell prints just the cd, shell-quoted" \
  "$(agent use platform --emit-shell)" "cd '$HOME/agentic-code/platform'"
expect_eq "sourcing the hook makes use cd the running bash" \
  "$(PATH="$HOME/.local/bin:$PATH" bash -c \
      'cd "$HOME"; . "$HOME/.config/guise/hook.sh"; guise use platform; printf %s "$PWD"')" \
  "$HOME/agentic-code/platform"
expect_eq "and passes every other subcommand straight through" \
  "$(PATH="$HOME/.local/bin:$PATH" bash -c \
      '. "$HOME/.config/guise/hook.sh"; guise default')" \
  "$APP_IDENT"
expect_fail "and reports failure without moving the shell" \
  env PATH="$HOME/.local/bin:$PATH" bash -c \
      '. "$HOME/.config/guise/hook.sh"; guise use nonesuch'
if command -v zsh >/dev/null; then
  expect_eq "sourcing the hook makes use cd the running zsh" \
    "$(PATH="$HOME/.local/bin:$PATH" zsh -c \
        'cd "$HOME"; . "$HOME/.config/guise/hook.sh"; guise use platform; printf %s "$PWD"')" \
    "$HOME/agentic-code/platform"
else
  skip "sourcing the hook makes use cd the running zsh (zsh not installed)"
fi

# The hook evals what --emit-shell printed, so an apostrophe anywhere in the
# path has to survive the round trip rather than ending the quoted word.
# Emitted by /bin/bash on purpose: bash 3.2 is the floor this script targets,
# and its pattern substitution is where the escaping goes wrong. The eval that
# checks the result can run under any bash -- a mangled quote is a syntax error
# in every one of them.
quoted_base="$HOME/pat's ünïcode guise"
git config -f "$HOME/.config/guise/config" core.basedir "$quoted_base"
emitted=$(/bin/bash "$GUISE" use platform --emit-shell </dev/null)
expect_eq "a quote in the path survives the eval the hook does" \
  "$(cd "$HOME" && eval "$emitted" 2>/dev/null; printf %s "$PWD")" \
  "$quoted_base/platform"
git config -f "$HOME/.config/guise/config" core.basedir "$HOME/agentic-code"

# A shell hook nobody sourced is a missing convenience, not a broken identity,
# so doctor says so without failing.
printf 'alias ll="ls -l"\n' > "$HOME/.zshrc"
agent doctor > "$SB/shellhook.out" 2>&1
expect_eq "doctor still exits 0 with the rc line gone" "$?" "0"
expect "and reports the shell hook as a warning, not a failure" \
  grep -q "^  warn  shell hook" "$SB/shellhook.out"

# An unrecognized shell has no rc to edit; setup must say so and carry on.
SHELL=/usr/bin/fish run_setup --store file --name fishy > "$SB/fishy.out" 2>&1
expect_eq "setup under an unrecognized shell still exits 0" "$?" "0"
expect "and points at the hook to source by hand" \
  grep -q "unrecognized shell" "$SB/fishy.out"

