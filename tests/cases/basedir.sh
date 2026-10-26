# --- basedir --------------------------------------------------------------------
echo "workspace directory:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "basedir prints the shared workspace" "$(agent basedir)" "$HOME/agentic-code"
git init -q "$HOME/agentic-code/$APP_IDENT/someclone"

agent basedir "$HOME/src" >/dev/null 2>&1
expect_eq "basedir exits 0" "$?" "0"
expect_eq "the new path is recorded" "$(cfg core.basedir)" "$HOME/src"
# The point of the whole subcommand: a clone left behind under the old path
# would fall out of includeIf scope and start committing as the human.
expect "clones move with the setting" test -d "$HOME/src/$APP_IDENT/someclone"
expect "the old directory is gone" test ! -e "$HOME/agentic-code/$APP_IDENT"
expect_eq "identity applies under the new path" \
  "$(git -C "$HOME/src/$APP_IDENT/someclone" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"
expect "AGENTS.md lands in the new workspace" test -f "$HOME/src/AGENTS.md"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes after the move" "$?" "0"
# Re-running with the path it already has moves nothing and breaks nothing.
agent basedir "$HOME/src" >/dev/null 2>&1
expect_eq "setting the path it already has is a no-op" "$?" "0"
expect "clones untouched by the no-op" test -d "$HOME/src/$APP_IDENT/someclone"

# Workspace roots are user-chosen paths, so a space in one must survive the
# move, the includeIf, and the walk doctor does.
agent basedir "$HOME/my agents" >/dev/null 2>&1
expect "a path with a space moves the clones" test -d "$HOME/my agents/$APP_IDENT/someclone"
expect_eq "and git still resolves the identity there" \
  "$(git -C "$HOME/my agents/$APP_IDENT/someclone" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"
agent doctor >/dev/null 2>&1
expect_eq "and doctor passes" "$?" "0"
agent basedir "$HOME/src" >/dev/null 2>&1

# A destination that sits inside a directory the same plan is moving: the first
# mv would succeed and the second land a tree inside itself, stranding the first
# identity under the second's scope with the config still saying the old thing.
# Nothing may move at all.
openssl genrsa -out "$SB/keyz.pem" 2048 2>/dev/null
run_setup --store file --name zeta --pem "$SB/keyz.pem" >/dev/null 2>&1
git init -q "$HOME/src/zeta/zclone"
expect_fail "basedir refuses a new root inside an identity that is also moving" \
  agent basedir "$HOME/src/zeta"
expect "and moves nothing when it refuses" test -d "$HOME/src/$APP_IDENT/someclone"
expect "including the identity the path named" test -d "$HOME/src/zeta/zclone"
expect_eq "with the setting untouched" "$(cfg core.basedir)" "$HOME/src"

# The same overlap reached through a symlink. Compared as typed, ~/link sits
# outside every identity directory; mv follows the link and lands inside one.
ln -s "$HOME/src/zeta" "$HOME/zlink"
expect_fail "basedir refuses a symlinked root that resolves into a moving identity" \
  agent basedir "$HOME/zlink"
expect "and still moves nothing" test -d "$HOME/src/$APP_IDENT/someclone"
expect "including through the link" test -d "$HOME/src/zeta/zclone"
# And the same overlap spelled with . and .. in a part of the path that does not
# exist yet, which no amount of resolving the existing prefix would catch.
expect_fail "basedir refuses an overlap reached through .." \
  agent basedir "$HOME/src/missing/../zeta"
expect_fail "basedir refuses an overlap reached through ." \
  agent basedir "$HOME/src/./zeta"
expect "and neither spelling moved anything" test -d "$HOME/src/$APP_IDENT/someclone"

# A symlinked root that resolves somewhere harmless is still a fine answer --
# the check must reject the overlap, not the symlink.
mkdir -p "$SB/realroot"
ln -s "$SB/realroot" "$HOME/goodlink"
agent basedir "$HOME/goodlink" >/dev/null 2>&1
expect_eq "but a symlinked root pointing somewhere else is accepted" "$?" "0"
expect "and the clones land through it" test -d "$SB/realroot/$APP_IDENT/someclone"
agent basedir "$HOME/src" >/dev/null 2>&1

# An identity staying put because it has its own workspace, but living inside
# one that is leaving: its clones would ride along out of their own scope.
agent basedir "$HOME/src/$APP_IDENT/nested" --name zeta >/dev/null 2>&1
expect "the nested identity moved" test -d "$HOME/src/$APP_IDENT/nested/zeta/zclone"
expect_fail "basedir refuses to move a directory another identity lives inside" \
  agent basedir "$HOME/faraway"
expect "leaving both where they were" test -d "$HOME/src/$APP_IDENT/nested/zeta/zclone"
agent basedir --unset --name zeta >/dev/null 2>&1

agent basedir "$HOME/elsewhere/../src" >/dev/null 2>&1
expect_eq "a path is recorded cleaned" "$(cfg core.basedir)" "$HOME/src"
expect_fail "basedir refuses a filesystem root" agent basedir /
expect_fail "and so does setup" run_setup --store file --name rooted --pem "$SB/key.pem" --base-dir /

# Renaming a directory rewrites its .. entry, so an unwritable one cannot move.
# The plan moves test-agent first and zeta second; test-agent has to come back.
if perms_enforced; then
  chmod 555 "$HOME/src/zeta"
  expect_fail "basedir fails when one of its moves does" agent basedir "$HOME/partial"
  chmod 755 "$HOME/src/zeta"
  expect "and puts back the moves it already made" test -d "$HOME/src/$APP_IDENT/someclone"
  expect "leaving nothing in the new root" test ! -e "$HOME/partial/$APP_IDENT"
  expect_eq "with the setting untouched" "$(cfg core.basedir)" "$HOME/src"
else
  skip "basedir puts back a partial move (no enforced modes here)"
fi

expect_fail "basedir refuses a relative path" agent basedir relative/path
mkdir -p "$HOME/occupied/$APP_IDENT"
expect_fail "basedir refuses an occupied destination" agent basedir "$HOME/occupied"
expect_eq "and changes nothing when it refuses" "$(cfg core.basedir)" "$HOME/src"
expect "and leaves the clones where they were" test -d "$HOME/src/$APP_IDENT/someclone"

# --- one workspace per identity -------------------------------------------------
echo "per-identity workspace:"
openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store file --name platform --pem "$SB/key2.pem" >/dev/null 2>&1
git init -q "$HOME/src/platform/theirclone"
agent basedir "$HOME/work" --name platform >/dev/null 2>&1
expect_eq "--name records an override" "$(cfg identity.platform.basedir)" "$HOME/work"
expect "the named identity moves" test -d "$HOME/work/platform/theirclone"
expect "and the others stay where they are" test -d "$HOME/src/$APP_IDENT/someclone"
expect_eq "the shared setting is untouched" "$(cfg core.basedir)" "$HOME/src"
expect_eq "basedir --name reports the override" "$(agent basedir --name platform)" "$HOME/work"
expect_eq "and falls back to the shared one for anyone else" \
  "$(agent basedir --name $APP_IDENT)" "$HOME/src"
expect_eq "the override wins in git, under the new root" \
  "$(git -C "$HOME/work/platform/theirclone" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"
expect_eq "which resolves the identity from the overridden path" \
  "$(cd "$HOME/work/platform/theirclone" && agent which)" "platform"
expect_eq "and the other identity from the shared one" \
  "$(cd "$HOME/src/$APP_IDENT/someclone" && agent which)" "$APP_IDENT"
expect_fail "which fails outside every identity directory" \
  env -u GUISE_IDENTITY bash -c "cd \"$HOME\" && \"$GUISE\" which"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes with two workspaces" "$?" "0"
expect_fail "basedir refuses --unset without --name" agent basedir --unset
expect_fail "basedir refuses a path and --unset together" agent basedir "$HOME/x" --unset
expect_fail "basedir refuses an unknown identity" agent basedir "$HOME/x" --name nonesuch

agent basedir --unset --name platform >/dev/null 2>&1
expect_eq "--unset drops the override" "$(cfg identity.platform.basedir 2>/dev/null)" ""
expect "and moves the identity back under the shared workspace" \
  test -d "$HOME/src/platform/theirclone"
expect "leaving nothing behind" test ! -e "$HOME/work/platform"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes after --unset" "$?" "0"

# Nested workspaces: the identity whose directory is the longest prefix of the
# path wins, not whichever one is listed first.
echo "nested workspaces:"
agent basedir "$HOME/src/nested" --name platform >/dev/null 2>&1
mkdir -p "$HOME/src/nested/platform/deep"
expect_eq "the innermost identity claims the path" \
  "$(cd "$HOME/src/nested/platform/deep" && agent which)" "platform"
agent basedir --unset --name platform >/dev/null 2>&1

