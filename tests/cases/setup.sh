# --- setup provisions everything --------------------------------------------
echo "setup:"
new_sandbox
run_setup --store op --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "setup exits 0" "$?" "0"
expect "config file written" test -f "$HOME/.config/guise/config"
expect_eq "slug discovered from API" "$(cfg identity.$APP_IDENT.slug)" "test-agent"
expect_eq "installation id discovered" "$(cfg identity.$APP_IDENT.installationid)" "2222"
expect_eq "bot user id discovered (not app id)" "$(cfg identity.$APP_IDENT.botuserid)" "3333"
expect_eq "basedir defaults to ~/agentic-code" "$(cfg core.basedir)" "$HOME/agentic-code"
expect "PEM shredded after storing" test ! -e "$SB/key.pem"
expect "private key landed in 1Password" test -f "$OP_FAKE_DIR/Private/test-agent/private_key"
expect "helpers installed" test -x "$HOME/.local/bin/guise-token"
expect "credential helper installed" test -x "$HOME/.local/bin/guise-credential"
expect "guise-gh installed" test -x "$HOME/.local/bin/guise-gh"
expect "hook installed" test -x "$HOME/.config/guise/git/agent-hooks/prepare-commit-msg"
expect "hook dispatcher installed" test -x "$HOME/.config/guise/git/hooks/prepare-commit-msg"
expect "identity dir created" test -d "$HOME/agentic-code/$APP_IDENT"
expect "AGENTS.md dropped in workspace" test -f "$HOME/agentic-code/AGENTS.md"
expect "CLAUDE.md imports AGENTS.md" grep -q '@AGENTS.md' "$HOME/agentic-code/CLAUDE.md"
expect_eq "exactly one marker block in ~/.gitconfig" \
  "$(grep -cF '# >>> guise >>>' "$HOME/.gitconfig")" "1"
expect "shell hook written" test -f "$HOME/.config/guise/hook.sh"
expect_eq "exactly one marker block in ~/.zshrc" \
  "$(grep -cF '# >>> guise >>>' "$HOME/.zshrc")" "1"

# --- idempotency -------------------------------------------------------------
echo "idempotency:"
snap1=$(snapshot)
echo "custom rules" > "$HOME/agentic-code/AGENTS.md"
run_setup >/dev/null 2>&1
expect_eq "re-run without --pem exits 0" "$?" "0"
"$GUISE" setup --name "$APP_IDENT" </dev/null >/dev/null 2>&1
expect_eq "a re-run by name alone finds the app's owner and App ID" "$?" "0"
"$GUISE" setup </dev/null >/dev/null 2>&1
expect_eq "and so does a bare re-run of the default" "$?" "0"
expect_eq "re-run changes no artifact" "$(snapshot)" "$snap1"
expect_eq "still exactly one marker block" \
  "$(grep -cF '# >>> guise >>>' "$HOME/.gitconfig")" "1"
expect_eq "and the rc line is not stacked up either" \
  "$(grep -cF '# >>> guise >>>' "$HOME/.zshrc")" "1"
expect_eq "edited AGENTS.md not overwritten" \
  "$(cat "$HOME/agentic-code/AGENTS.md")" "custom rules"

# --- second identity ---------------------------------------------------------
echo "multiple identities:"
openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store op --name platform --pem "$SB/key2.pem" >/dev/null 2>&1
expect_eq "second identity setup exits 0" "$?" "0"
expect_eq "two includeIf blocks in owned gitconfig" \
  "$(grep -c includeIf "$HOME/.config/guise/gitconfig")" "2"
expect_eq "~/.gitconfig untouched by second identity" \
  "$(grep -cF '# >>> guise >>>' "$HOME/.gitconfig")" "1"
expect "platform dir created" test -d "$HOME/agentic-code/platform"
run_setup --store op --name reused >/dev/null 2>&1
expect_eq "new identity without --pem reuses the stored key" "$?" "0"
expect_eq "reused identity fully discovered" "$(cfg identity.reused.installationid)" "2222"

# --- identity applies inside scope, hook behaves -----------------------------
echo "scoped identity + trailer hook:"
repo="$HOME/agentic-code/$APP_IDENT/hooktest"
git init -q "$repo"
expect_eq "bot identity applies inside scope" \
  "$(git -C "$repo" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"
expect_eq "gpgsign off inside scope" "$(git -C "$repo" config --get commit.gpgsign)" "false"
expect_eq "human identity intact outside scope" \
  "$(git -C "$SB" config --get user.email)" "human@example.com"
( cd "$repo" && echo x > f && git add f && git commit -q -m "test commit" )
expect_eq "commit authored by bot" \
  "$(git -C "$repo" log -1 --format='%an')" "test-agent[bot]"
expect_eq "co-author trailer added on commit -m" \
  "$(git -C "$repo" log -1 --format=%B | grep -c '^Co-authored-by: Human <human@example.com>$')" "1"
( cd "$repo" && git commit -q --amend --no-edit )
expect_eq "trailer not duplicated on --amend" \
  "$(git -C "$repo" log -1 --format=%B | grep -c '^Co-authored-by:')" "1"

# A harness hands git a message that already credits itself. The human has to
# displace that, not defer to it -- interpret-trailers on its own defers,
# because it matches the token and never looks at who is named.
( cd "$repo" && echo y > g && git add g && git commit -q -m "harness commit

Co-Authored-By: Cursor Agent <cursoragent@cursor.com>" )
expect_eq "harness co-author replaced by the human" \
  "$(git -C "$repo" log -1 --format=%B | grep -i '^Co-authored-by:')" \
  "Co-authored-by: Human <human@example.com>"

# Replaying someone else's commit makes the identity its committer, not an
# author. Crediting the human there claims a share of a patch neither of them
# wrote -- once via --author, and once via the cherry-pick that adopts it.
( cd "$repo" && git checkout -q -b outside HEAD~1 && echo z > h && git add h \
  && git commit -q -m "outside contribution" --author="Outsider <out@example.com>" )
expect_eq "no trailer on a commit made with --author" \
  "$(git -C "$repo" log -1 --format=%B | grep -c '^Co-authored-by:')" "0"
( cd "$repo" && git checkout -q - && git cherry-pick outside >/dev/null )
expect_eq "cherry-pick keeps the original author" \
  "$(git -C "$repo" log -1 --format='%an')" "Outsider"
expect_eq "and no trailer credits the human for it" \
  "$(git -C "$repo" log -1 --format=%B | grep -c '^Co-authored-by:')" "0"

# A clean revert leaves no REVERT_HEAD behind -- the sequencer keeps that marker
# only while it is stopped -- so the generated message is the only thing left to
# recognise the replay by.
( cd "$repo" && git revert --no-edit HEAD >/dev/null )
expect_eq "no trailer on a clean revert" \
  "$(git -C "$repo" log -1 --format=%B | grep -c '^Co-authored-by:')" "0"

# Reimplementing a contribution leaves no commit of theirs to preserve, so the
# trailer is the only credit its author gets -- the hook clears the harness and
# the identity's own redundant credit, and nothing else. The bot address is the
# reason this matches whole addresses and not a pattern: it is full of regex.
( cd "$repo" && echo w > i && git add i && git commit -q -m "reimplemented contribution

Co-Authored-By: Claude <noreply@anthropic.com>
Co-authored-by: test-agent[bot] <3333+test-agent[bot]@users.noreply.github.com>
Co-authored-by: Contributor <c@example.com>" )
expect_eq "the contributor and the human are the only co-authors left" \
  "$(git -C "$repo" log -1 --format=%B | grep -i '^Co-authored-by:' | tr '\n' '|')" \
  "Co-authored-by: Contributor <c@example.com>|Co-authored-by: Human <human@example.com>|"

# A missing global identity must not abort the commit: git config exits 1 on an
# unset key and the hook runs under set -e. Driven directly rather than through a
# commit, so unsetting the global identity can't reorder ~/.gitconfig and leave
# [user] winning over the include.
hook="$HOME/.config/guise/git/agent-hooks/prepare-commit-msg"
mkdir -p "$SB/nohome"
printf 'a commit subject\n' > "$SB/msg.txt"
( HOME="$SB/nohome" "$hook" "$SB/msg.txt" ) >/dev/null 2>&1
expect_eq "hook exits 0 when there is no identity to credit" "$?" "0"
expect_eq "and leaves the message without a trailer" \
  "$(grep -c '^Co-authored-by:' "$SB/msg.txt")" "0"
printf 'a commit subject\n' > "$SB/msg.txt"
( GUISE_CO_AUTHOR="Someone <s@example.com>" "$hook" "$SB/msg.txt" ) >/dev/null 2>&1
expect_eq "and still adds the trailer when one is available" \
  "$(grep -c '^Co-authored-by: Someone <s@example.com>$' "$SB/msg.txt")" "1"

# Clearing the co-author token is not licence to touch the rest of the block.
printf 'a commit subject\n\nSigned-off-by: Someone <s@example.com>\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > "$SB/msg.txt"
( GUISE_CO_AUTHOR="Human <human@example.com>" "$hook" "$SB/msg.txt" ) >/dev/null 2>&1
expect_eq "an unrelated trailer survives the strip" \
  "$(grep -c '^Signed-off-by: Someone <s@example.com>$' "$SB/msg.txt")" "1"
expect_eq "and the harness co-author is gone, whatever its casing" \
  "$(grep -i '^Co-authored-by:' "$SB/msg.txt")" "Co-authored-by: Human <human@example.com>"

# addIfDifferent compares the trailer verbatim, so a message that already
# credits the human in another spelling would otherwise get a second one.
printf 'a commit subject\n\nCo-Authored-By: HUMAN <Human@Example.com>\n' > "$SB/msg.txt"
( GUISE_CO_AUTHOR="Human <human@example.com>" "$hook" "$SB/msg.txt" ) >/dev/null 2>&1
expect_eq "the human's own trailer is not duplicated by a different spelling" \
  "$(grep -i -c '^Co-authored-by:' "$SB/msg.txt")" "1"

# --- token cache -------------------------------------------------------------
echo "token cache:"
rm -rf "$XDG_CACHE_HOME/guise"; : > "$CURL_LOG"
t1=$("$HOME/.local/bin/guise-token" "$APP_IDENT")
t2=$("$HOME/.local/bin/guise-token" "$APP_IDENT")
expect_eq "second call returns cached token" "$t1" "$t2"
expect_eq "only one mint against the API" "$(grep -c access_tokens "$CURL_LOG")" "1"

# --- doctor ------------------------------------------------------------------
echo "doctor:"
"$GUISE" doctor >/dev/null 2>&1
expect_eq "doctor passes on a healthy install" "$?" "0"

# A valid credential that reaches zero repos passes every other check and only
# fails at clone time -- doctor has to catch it.
FAKE_REPO_COUNT=0 "$GUISE" doctor > "$SB/doctor.out" 2>&1
expect_eq "doctor fails when the installation reaches no repos" "$?" "1"
expect "the failure names the installation reachability check" \
  grep -q "FAIL  installation reaches at least one repository" "$SB/doctor.out"
"$GUISE" doctor >/dev/null 2>&1
expect_eq "doctor passes again once the installation has a repo" "$?" "0"

# A guise-gh from before it checked the token puts guise-token's failure in an
# assignment prefix, where exec discards it and gh runs as the human. Doctor
# has to judge the installed copy, which only update rewrites.
cat > "$HOME/.local/bin/guise-gh" <<'OLD'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GH_TOKEN="$("$HERE/guise-token" "${GUISE_IDENTITY:-}")" exec gh "$@"
OLD
agent doctor > "$SB/doctor.out" 2>&1
expect_eq "doctor fails on a guise-gh that runs gh when the token fails" "$?" "1"
expect "the failure names the fail-closed check" \
  grep -q "FAIL  guise-gh refuses to run gh without the identity's token" "$SB/doctor.out"
expect "and its hint points at update" grep -q "run 'guise update'" "$SB/doctor.out"
agent update >/dev/null 2>&1
agent doctor >/dev/null 2>&1
expect_eq "doctor passes once update reinstalls guise-gh" "$?" "0"

