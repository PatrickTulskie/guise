# --- PATH ----------------------------------------------------------------------
# Agents are told to use guise-gh, and one whose shell can't find it reaches for
# plain gh, as the human. So setup calls out a PATH without ~/.local/bin, and
# doctor fails unless each helper PATH finds is the installed one -- an earlier
# directory or an exported function can both put something else there.
echo "PATH:"
new_sandbox
hint_for() { grep -A1 "$1" "$2" | sed -n 's/^ *hint: //p'; }
this_version=$(agent --version | cut -d' ' -f2)
# REAL_PATH may carry the developer's own install, which would resolve in place
# of the sandbox's; drop those directories so nothing named guise does.
nobin="$ROOT/tests/stubs"
IFS=: read -r -a dirs <<<"$REAL_PATH"
for d in "${dirs[@]}"; do [[ -e "$d/guise" || -e "$d/guise-gh" ]] || nobin="$nobin:$d"; done
PATH="$nobin" run_setup --store file --pem "$SB/key.pem" > "$SB/setup.out" 2>&1
expect "setup calls out that ~/.local/bin is off PATH, naming the rc" \
  grep -qF 'Add this line to ~/.zshrc' "$SB/setup.out"
expect "and gives the line to add" \
  grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$SB/setup.out"
PATH="$nobin" agent doctor > "$SB/doctor.out" 2>&1
expect_eq "doctor fails with ~/.local/bin off PATH" "$?" "1"
expect_eq "the resolve check's hint gives the same line" \
  "$(hint_for 'FAIL  helper binaries resolve on PATH' "$SB/doctor.out")" \
  '~/.local/bin is not on PATH -- add this to ~/.zshrc, then open a new shell:  export PATH="$HOME/.local/bin:$PATH"'
expect "guise itself fails to resolve too" grep -q "FAIL  guise resolves on PATH" "$SB/doctor.out"
expect_eq "and the version note defers to that check" \
  "$(hint_for 'warn  guise on PATH is this version' "$SB/doctor.out")" \
  "nothing named guise is on PATH -- fix the check above"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes with ~/.local/bin back on PATH" "$?" "0"

mkdir -p "$SB/shadow" "$SB/stale"
printf '#!/bin/sh\n' > "$SB/shadow/guise-gh"
printf '#!/bin/sh\necho guise 0.0.1\n' > "$SB/stale/guise"
chmod 755 "$SB/shadow/guise-gh" "$SB/stale/guise"
PATH="$SB/shadow:$PATH" agent doctor > "$SB/doctor.out" 2>&1
expect_eq "doctor fails when an earlier directory holds another guise-gh" "$?" "1"
expect_eq "and names it" \
  "$(hint_for 'FAIL  helper binaries resolve on PATH' "$SB/doctor.out")" \
  "$SB/shadow/guise-gh shadows $HOME/.local/bin/guise-gh -- remove it, or put ~/.local/bin ahead of $SB/shadow on PATH"
guise-gh() { :; }; export -f guise-gh
agent doctor > "$SB/doctor.out" 2>&1
expect_eq "doctor fails when an exported function shadows guise-gh" "$?" "1"
unset -f guise-gh
expect_eq "and says to unset it" \
  "$(hint_for 'FAIL  helper binaries resolve on PATH' "$SB/doctor.out")" \
  "a shell function named guise-gh shadows $HOME/.local/bin/guise-gh -- unset -f guise-gh, and take its definition (and any export -f) out of your shell config"
PATH="$SB/stale:$PATH" agent doctor > "$SB/doctor.out" 2>&1
expect_eq "a stale guise ahead on PATH is a warning, not a failure" "$?" "0"
expect_eq "that names the copy and its version" \
  "$(hint_for 'warn  guise on PATH is this version' "$SB/doctor.out")" \
  "$SB/stale/guise reports 'guise 0.0.1' and this is guise $this_version -- run 'guise update' from the newer copy, or remove the stale one"

