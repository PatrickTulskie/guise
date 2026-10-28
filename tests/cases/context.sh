# --- context -----------------------------------------------------------------
# Codex reads AGENTS.md from the git root down and never above it, so the one
# at the top of the workspace reaches it through a SessionStart hook that runs
# `guise context`. Every other harness walks up and finds the file itself.
echo "context:"
new_sandbox
export FAKE_GH_LOGIN=PatrickTulskie
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
hooks="$HOME/.codex/hooks.json"
expect "no Codex home, no hook written" test ! -e "$hooks"
agent doctor > "$SB/doctor.out" 2>&1
expect_fail "and doctor says nothing about Codex" grep -q Codex "$SB/doctor.out"

# What Codex hands the hook: one JSON object on stdin, cwd among its fields.
hook() { printf '{"session_id":"x","cwd":"%s","hook_event_name":"SessionStart"}' "$(git_path "$1")" | "$GUISE" context; }
rules="$HOME/agentic-code/AGENTS.md"
repo="$HOME/agentic-code/$APP_IDENT/some/repo"
git init -q "$repo"
expect_eq "from the identity directory, the workspace AGENTS.md" "$(hook "$HOME/agentic-code/$APP_IDENT")" "$(cat "$rules")"
expect_eq "from inside a clone too" "$(hook "$repo")" "$(cat "$rules")"
expect_eq "and from the workspace root itself" "$(hook "$HOME/agentic-code")" "$(cat "$rules")"
expect_eq "outside the workspace, nothing" "$(hook "$HOME")" ""
expect "and exit 0, so the hook never fails the session" hook "$HOME"
expect_eq "a sibling whose name merely starts with the workspace's" "$(mkdir -p "$HOME/agentic-code2" && hook "$HOME/agentic-code2")" ""
echo "custom rules" > "$rules"
expect_eq "the file as edited, not the built-in text" "$(hook "$repo")" "custom rules"
expect_eq "no stdin: the current directory" "$(cd "$repo" && "$GUISE" context </dev/null)" "custom rules"
expect_eq "stdin that isn't a hook's JSON: the current directory" "$(cd "$repo" && echo garbage | "$GUISE" context)" "custom rules"
expect_eq "without a config: nothing" "$(GUISE_CONFIG="$SB/none" hook "$repo")" ""
expect "and still exit 0" env GUISE_CONFIG="$SB/none" "$GUISE" context </dev/null
expect_fail "context takes no arguments" agent context "$repo"

# A per-identity workspace is a root of its own, with rules of its own.
mkdir -p "$HOME/work"
agent basedir "$HOME/work" --name "$APP_IDENT" >/dev/null 2>&1
echo "work rules" > "$HOME/work/AGENTS.md"
expect_eq "a per-identity workspace answers with its own AGENTS.md" "$(hook "$HOME/work/$APP_IDENT/x")" "work rules"
expect_eq "the shared one still answers for the rest" "$(hook "$HOME/agentic-code/other")" "custom rules"

# A machine with Codex on it, and hooks of its own already in the file.
mkdir "$HOME/.codex"
cat > "$hooks" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"echo hi && echo <there>"}]},{"hooks":[{"type":"command","command":"/opt/disguise context"}]}],"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}
JSON
agent update > "$SB/update.out" 2>&1
expect "update writes the hook" grep -q "session hook" "$SB/update.out"
ours() { jq -r '.hooks.SessionStart[].hooks[] | select(.command | test("[/'"'"']guise(\\.exe)?'"'"'? context$")) | .command' "$hooks"; }
expect_eq "one SessionStart handler runs guise context" "$(ours | grep -c .)" "1"
expect "naming the installed guise, not the one being run" grep -qF "$(git_path "$HOME/.local/bin/guise$EXE")" "$hooks"
expect_eq "the user's SessionStart hook survived" "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$hooks")" 'echo hi && echo <there>'
expect "written as it was, not as \\u0026\\u0026" grep -qF 'echo hi && echo <there>' "$hooks"
expect "a command that merely ends in context is someone else's" grep -qF '/opt/disguise context' "$hooks"
expect_eq "and the Stop hook with it" "$(jq -r '.hooks.Stop[0].hooks[0].command' "$hooks")" "say done"
# Run what Codex runs: the command out of the file, with the hook's stdin.
expect_eq "the command Codex runs prints the workspace rules" \
  "$(printf '{"cwd":"%s"}' "$(git_path "$repo")" | sh -c "$(ours)")" "custom rules"
snap=$(digest < "$hooks")
agent update >/dev/null 2>&1
expect_eq "a second update leaves the file byte-identical" "$(digest < "$hooks")" "$snap"
agent doctor > "$SB/doctor.out" 2>&1
expect "doctor reports the hook" grep -q "ok.*Codex session hook" "$SB/doctor.out"

# A hook from an install at another path is replaced, not joined by a second.
jq '(.hooks.SessionStart[].hooks[] | select(.command | contains("guise'"'"' context")) | .command) = "/old/guise context"' "$hooks" > "$SB/old.json"
mv "$SB/old.json" "$hooks"
agent doctor > "$SB/doctor.out" 2>&1
expect "doctor flags a hook that runs another guise" grep -q "warn.*Codex session hook" "$SB/doctor.out"
agent update >/dev/null 2>&1
expect_eq "update replaces it" "$(ours | grep -c .)" "1"
expect_fail "and the old one is gone" grep -q /old/guise "$hooks"
expect_eq "setup keeps it current too" "$(echo '{}' > "$hooks"; run_setup --store file >/dev/null 2>&1; ours | grep -c .)" "1"

echo '{oops' > "$hooks"
agent update > "$SB/update.out" 2>&1
expect_eq "a hooks.json that isn't JSON stops update" "$?" "1"
expect "saying which file to fix" grep -q "hooks.json is not a JSON object" "$SB/update.out"
expect_eq "and is left as it was" "$(cat "$hooks")" "{oops"

# Uninstall takes guise's entry and nothing else; the file goes only when
# that entry was all it held.
cat > "$hooks" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"echo hi"}]},{"hooks":[{"type":"command","command":"/opt/disguise context"}]}]}}
JSON
agent update >/dev/null 2>&1
agent uninstall -y > "$SB/uninstall.out" 2>&1
expect "uninstall says it removed the hook" grep -q "session hook" "$SB/uninstall.out"
expect_eq "guise's handler is gone" "$(ours | grep -c .)" "0"
expect_eq "the user's stays" "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$hooks")" "echo hi"
expect_eq "and so does the one that only sounds like ours" "$(jq -r '.hooks.SessionStart[1].hooks[0].command' "$hooks")" "/opt/disguise context"
openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store file --pem "$SB/key2.pem" >/dev/null 2>&1
echo '{}' > "$hooks"
agent update >/dev/null 2>&1
agent uninstall -y >/dev/null 2>&1
expect "a file holding only guise's hook is removed" test ! -e "$hooks"
expect "the Codex home itself is left alone" test -d "$HOME/.codex"
