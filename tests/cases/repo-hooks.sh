# --- a repository's own hooks keep running -----------------------------------
# Git runs one hooks directory per repository and agent scope names guise's, so
# everything a repo keeps in .git/hooks would otherwise go silent on agent
# commits. A dispatcher stands in: the repo's hook first, then guise's.
echo "repository hooks:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
dispatch="$HOME/.config/guise/git/hooks"
repo="$HOME/agentic-code/$APP_IDENT/plain"
git init -q "$repo"
expect_eq "agent scope points git at the dispatcher" \
  "$(git -C "$repo" config --get core.hooksPath)" "$(git_path "$dispatch")"
expect "which has an entry for every hook git looks up by name" \
  test -x "$dispatch/pre-commit" -a -x "$dispatch/pre-push" -a -x "$dispatch/reference-transaction"

printf '#!/bin/sh\ntouch pre-commit-ran\nexit 1\n' > "$repo/.git/hooks/pre-commit"
chmod +x "$repo/.git/hooks/pre-commit"
( cd "$repo" && echo x > f && git add f && git commit -q -m "refused" ) >/dev/null 2>&1
expect "a .git/hooks/pre-commit that fails runs" test -f "$repo/pre-commit-ran"
expect_fail "and refuses the agent's commit" git -C "$repo" rev-parse -q --verify HEAD
printf '#!/bin/sh\ntouch pre-commit-ok\n' > "$repo/.git/hooks/pre-commit"
( cd "$repo" && git commit -q -m "allowed" ) >/dev/null 2>&1
expect "one that passes lets it through" test -f "$repo/pre-commit-ok"
expect_eq "with the co-author trailer still added after it" \
  "$(git -C "$repo" log -1 --format=%B | grep -c '^Co-authored-by: Human <human@example.com>$')" "1"

# A linked worktree has no hooks of its own; the main repository's apply.
wt="$HOME/agentic-code/$APP_IDENT/plain-wt"
git -C "$repo" worktree add -q "$wt" -b wt >/dev/null 2>&1
( cd "$wt" && echo z > z && git add z && git commit -q -m "in a worktree" ) >/dev/null 2>&1
expect "a hook in the main repo's .git/hooks runs for a commit in a linked worktree" \
  test -f "$wt/pre-commit-ok"

# Hooks git talks to on stdin have to hear it through the dispatcher.
git init -q --bare "$SB/remote.git"
git -C "$repo" remote add origin "$SB/remote.git"
printf '#!/bin/sh\ncat > pre-push-stdin\n' > "$repo/.git/hooks/pre-push"
chmod +x "$repo/.git/hooks/pre-push"
git -C "$repo" push -q origin main >/dev/null 2>&1
expect_eq "pre-push receives the ref lines git hands it on stdin" \
  "$(cut -d' ' -f1,3 "$repo/pre-push-stdin" 2>/dev/null)" "refs/heads/main refs/heads/main"

# A clone that left its identity's directory may still name the dispatcher.
# Its own hooks keep running there; the human's commits get no trailer.
stray="$SB/stray"
git init -q "$stray"
git -C "$stray" config --local core.hooksPath "$dispatch"
printf '#!/bin/sh\ntouch stray-ran\n' > "$stray/.git/hooks/pre-commit"
chmod +x "$stray/.git/hooks/pre-commit"
( cd "$stray" && echo a > a && git add a && git -c commit.gpgsign=false commit -q -m "human commit" ) >/dev/null 2>&1
expect "outside agent scope the dispatcher still runs the repo's own hooks" test -f "$stray/stray-ran"
expect_eq "and adds no co-author trailer" \
  "$(git -C "$stray" log -1 --format=%B | grep -c '^Co-authored-by:')" "0"

# A repo-local core.hooksPath wins over the conf's, so a repo whose hook manager
# pins one silences guise's hook instead. setup-hooks records that path and
# points the repo at the dispatcher, which runs the recorded hooks first -- a
# prepare-commit-msg that writes the whole message would wipe a trailer added
# ahead of it.
pinned="$HOME/agentic-code/$APP_IDENT/pinned"
git init -q "$pinned"
mkdir -p "$pinned/.githooks"
printf '#!/bin/sh\nprintf "message from the repo hook\\n" > "$1"\ntouch repo-hook-ran\n' \
  > "$pinned/.githooks/prepare-commit-msg"
chmod +x "$pinned/.githooks/prepare-commit-msg"
git -C "$pinned" config --local core.hooksPath .githooks
tree_before=$(git -C "$pinned" status --porcelain)
( cd "$pinned" && agent setup-hooks ) >/dev/null 2>&1
expect_eq "setup-hooks exits 0" "$?" "0"
expect_eq "it records the path the repo pinned" \
  "$(git -C "$pinned" config --local --get guise.innerhookspath)" ".githooks"
expect_eq "and points the repo at the dispatcher" \
  "$(git -C "$pinned" config --local --get core.hooksPath)" "$(git_path "$dispatch")"
expect_eq "and touches nothing in the working tree" \
  "$(git -C "$pinned" status --porcelain)" "$tree_before"
( cd "$pinned" && echo x > f && git add f && git commit -q -m "typed message" ) >/dev/null 2>&1
expect_eq "the repo's hook wrote the message" \
  "$(git -C "$pinned" log -1 --format=%s)" "message from the repo hook"
expect "and left its marker" test -f "$pinned/repo-hook-ran"
expect_eq "and the human's trailer came after it" \
  "$(git -C "$pinned" log -1 --format=%B | grep -c '^Co-authored-by: Human <human@example.com>$')" "1"

snap=$(git -C "$pinned" config --local --list | shasum)
( cd "$pinned" && agent setup-hooks ) >/dev/null 2>&1
expect_eq "running setup-hooks again changes nothing" \
  "$(git -C "$pinned" config --local --list | shasum)" "$snap"
# The hook manager re-applied its path on the next install.
git -C "$pinned" config --local core.hooksPath .husky/_
( cd "$pinned" && agent setup-hooks ) >/dev/null 2>&1
expect_eq "a path a tool put back is recorded afresh" \
  "$(git -C "$pinned" config --local --get guise.innerhookspath)" ".husky/_"
git init -q "$SB/outside"
( cd "$SB/outside" && agent setup-hooks ) > "$SB/outside.out" 2>&1
expect_eq "setup-hooks refuses a repo no identity owns" "$?" "1"
expect "and says so" grep -q 'belongs to no identity' "$SB/outside.out"

# A manager that pins the path during the clone's first bootstrap, stood in
# for by the template git copies into every new repository.
mkdir -p "$SB/origins/owner" "$SB/tmpl"
git init -q --bare "$SB/origins/owner/managed.git"
git config --global url."$SB/origins/".insteadOf "https://github.com/"
printf '[core]\n\thooksPath = .githooks\n' > "$SB/tmpl/config"
git config --global init.templateDir "$SB/tmpl"
( cd "$HOME/agentic-code/$APP_IDENT" && agent clone owner/managed ) >/dev/null 2>&1
git config --global --unset init.templateDir
managed="$HOME/agentic-code/$APP_IDENT/managed"
expect_eq "clone sets a fresh clone up on the spot" \
  "$(git -C "$managed" config --local --get core.hooksPath)" "$(git_path "$dispatch")"
expect_eq "recording the path it arrived with" \
  "$(git -C "$managed" config --local --get guise.innerhookspath)" ".githooks"

( cd "$pinned" && agent doctor ) >/dev/null 2>&1
expect_eq "doctor passes inside a repo that is set up" "$?" "0"
git -C "$pinned" config --local core.hooksPath .husky/_
( cd "$pinned" && agent doctor ) > "$SB/doctor.out" 2>&1
expect_eq "and fails once the repo's tooling has reset the path" "$?" "1"
expect "naming the repository check" grep -q "FAIL  this repository runs its hooks through guise" "$SB/doctor.out"
expect "and pointing at setup-hooks" grep -q "hint: run 'guise setup-hooks' here" "$SB/doctor.out"
( cd "$pinned" && agent setup-hooks ) >/dev/null 2>&1

# Taking the wiring away must hand each repo its own path back, or it points
# at a dispatcher that is gone and git runs no hooks at all.
openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store file --name platform --pem "$SB/key2.pem" >/dev/null 2>&1
theirs="$HOME/agentic-code/platform/pinned"
git init -q "$theirs"
git -C "$theirs" config --local core.hooksPath .githooks
( cd "$theirs" && agent setup-hooks ) >/dev/null 2>&1
agent rm platform --keep >/dev/null 2>&1
expect_eq "rm hands a clone it keeps its own hooks path back" \
  "$(git -C "$theirs" config --local --get core.hooksPath)" ".githooks"
expect_fail "and drops the record" git -C "$theirs" config --local --get guise.innerhookspath
expect_eq "leaving other identities' clones alone" \
  "$(git -C "$pinned" config --local --get core.hooksPath)" "$(git_path "$dispatch")"
agent uninstall --yes >/dev/null 2>&1
expect_eq "uninstall restores the recorded path byte for byte" \
  "$(git -C "$pinned" config --local --get core.hooksPath)" ".husky/_"
expect_fail "and drops the record" git -C "$pinned" config --local --get guise.innerhookspath
expect_fail "a repo that never pinned a path is left without one" \
  git -C "$repo" config --local --get core.hooksPath

