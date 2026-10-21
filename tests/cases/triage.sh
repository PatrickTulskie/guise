# --- triage ------------------------------------------------------------------
# Every fake harness records where it started and exactly what argv it got, so
# a test can tell a prompt handed over whole from one split or mangled on the
# way. They sit ahead of PATH, so a real harness on the host is never launched.
echo "triage:"
new_sandbox
fake_harness() { # name
  mkdir -p "$SB/harness"
  cat > "$SB/harness/$1" <<EOF
#!/usr/bin/env bash
pwd -P > "$SB/harness/$1.cwd"
echo \$# > "$SB/harness/$1.argc"
i=0; for a; do i=\$((i+1)); printf '%s' "\$a" > "$SB/harness/$1.arg\$i"; done
EOF
  chmod +x "$SB/harness/$1"
}
fake_harness claude
fake_harness opencode

agent triage --print > "$SB/no-config.prompt"
expect_eq "triage needs no config, since setup may be what failed" "$?" "0"
expect "and the prompt says so" grep -q "missing -- setup may never have finished" "$SB/no-config.prompt"

run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
trepo="$HOME/agentic-code/$APP_IDENT/broken"
git init -q "$trepo"
prompt=$(cd "$trepo" && agent triage --print)
expect "the prompt names the identity owning where triage started" \
  grep -qF "$trepo, identity '$APP_IDENT''s directory" <<<"$prompt"
expect "and points the agent at the source it is running" \
  grep -qxF "     $ROOT/cmd/guise" <<<"$prompt"
expect "and at the docs that ship with it" \
  grep -qxF "     $ROOT/docs/troubleshooting.md" <<<"$prompt"
expect_eq "with no terminal, a bare triage prints the prompt rather than launching" \
  "$(cd "$trepo" && PATH="$SB/harness:$PATH" agent triage)" "$prompt"
expect "and starts nothing" test ! -e "$SB/harness/claude.argc"

(cd "$trepo" && PATH="$SB/harness:$PATH" agent triage --harness claude)
expect_eq "--harness hands the prompt over as one argument" "$(cat "$SB/harness/claude.argc")" "1"
expect_eq "intact" "$(cat "$SB/harness/claude.arg1")" "$prompt"
expect_eq "in the directory triage was started from" "$(cat "$SB/harness/claude.cwd")" "$(cd "$trepo" && pwd -P)"
(cd "$trepo" && PATH="$SB/harness:$PATH" agent triage --harness opencode)
expect_eq "opencode gets it through --prompt" \
  "$(cat "$SB/harness/opencode.argc") $(cat "$SB/harness/opencode.arg1")" "2 --prompt"
expect_eq "intact too" "$(cat "$SB/harness/opencode.arg2")" "$prompt"

expect "an unsupported harness is refused" \
  grep -qF "unknown harness 'no-such-harness'" <<<"$(agent triage --harness no-such-harness 2>&1)"
expect "so is one that isn't installed" \
  grep -qF "pi is not on your PATH" <<<"$(PATH="/usr/bin:/bin" agent triage --harness pi 2>&1)"

# On a terminal it asks which harness; enter takes the first one found.
if have_pty; then
  rm -f "$SB"/harness/*.arg* "$SB"/harness/*.cwd
  printf '\n' | PATH="$SB/harness:$PATH" TERM=dumb in_pty "cd '$trepo' && '$GUISE' triage" > "$SB/triage.out" 2>&1
  expect "on a terminal, triage offers the harnesses it found" grep -q "Claude Code" "$SB/triage.out"
  expect_eq "and launches the one picked" "$(cat "$SB/harness/claude.arg1" 2>/dev/null)" "$prompt"
  rm -f "$SB"/harness/*.arg* "$SB"/harness/*.cwd
  printf 'print\n' | PATH="$SB/harness:$PATH" TERM=dumb in_pty "cd '$trepo' && '$GUISE' triage" > "$SB/triage.out" 2>&1
  expect "or prints the prompt when asked to" grep -q "You're helping someone" "$SB/triage.out"
  expect "without launching anything" test ! -e "$SB/harness/claude.cwd"
else
  skip "on a terminal, triage offers the harnesses it found (no script, so no pty)"
fi

