# --- op-cache key store ------------------------------------------------------
# The same 1Password item an op store uses; what changes is that reads go
# through op-cache, which remembers the answer for the rest of the login
# session.
echo "op-cache key store:"
new_sandbox
printf 'github_pat_cached\n' > "$SB/pat.txt"
run_setup_user --store op-cache --token-file "$SB/pat.txt" >/dev/null 2>&1
expect_eq "op-cache setup exits 0" "$?" "0"
expect_eq "keysource recorded" "$(cfg identity.$USER_IDENT.keysource)" "op-cache"
expect_eq "the token is in the 1Password item" \
  "$(cat "$OP_FAKE_DIR/Private/patrick-agent/token")" "github_pat_cached"
expect "and not in a file" test ! -e "$HOME/.config/guise/keys/$USER_IDENT.token"
: > "$OP_CACHE_LOG"
expect_eq "guise-token reads through op-cache" \
  "$("$HOME/.local/bin/guise-token" "$USER_IDENT")" "github_pat_cached"
expect_eq "with the account after the subcommand, where op-cache caches it" \
  "$(cat "$OP_CACHE_LOG")" "read --account my.1password.com op://Private/patrick-agent/token"
# The whole point: once read, a locked vault is no longer in the way.
expect_eq "a later read is served with 1Password unreachable" \
  "$(OP_FAKE_FORBID=1 "$HOME/.local/bin/guise-token" "$USER_IDENT")" "github_pat_cached"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes with an op-cache store" "$?" "0"

# Rotation: the item changes under a cache that would otherwise keep answering
# with the old token until the daemon exits.
printf 'github_pat_rotated\n' > "$SB/pat2.txt"
run_setup_user --token-file "$SB/pat2.txt" >/dev/null 2>&1
expect_eq "rotating an op-cache identity's token exits 0" "$?" "0"
expect_eq "and keeps op-cache" "$(cfg identity.$USER_IDENT.keysource)" "op-cache"
expect_eq "with the new token reading back, not the cached one" \
  "$("$HOME/.local/bin/guise-token" "$USER_IDENT")" "github_pat_rotated"

# An app identity's key takes the same path, so a JWT still signs with the
# vault locked once the key has been read this session.
run_setup --store op-cache --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "an app identity into op-cache exits 0" "$?" "0"
t=$("$HOME/.local/bin/guise-token" "$APP_IDENT")
expect_eq "its token mints" "${t:0:4}" "ghs_"
rm -f "$XDG_CACHE_HOME/guise/$APP_IDENT.token.json"
t=$(OP_FAKE_FORBID=1 "$HOME/.local/bin/guise-token" "$APP_IDENT")
expect_eq "and mints again from the cached key with 1Password unreachable" "${t:0:4}" "ghs_"

# Moving between stores is a re-run with a different --store. Into op-cache
# from a file shreds the file the way a move into 1Password does; between op
# and op-cache only the reader changes; back to a file leaves the item alone.
new_sandbox
printf 'github_pat_moving\n' > "$SB/pat.txt"
run_setup_user --store file --token-file "$SB/pat.txt" >/dev/null 2>&1
tokenfile="$HOME/.config/guise/keys/$USER_IDENT.token"
run_setup_user --store op-cache >/dev/null 2>&1
expect_eq "a move from a file into op-cache exits 0" "$?" "0"
expect "and shreds the file it moved out of" test ! -e "$tokenfile"
expect_eq "with the token in 1Password" \
  "$(cat "$OP_FAKE_DIR/Private/patrick-agent/token")" "github_pat_moving"
expect_eq "reading back through op-cache" \
  "$("$HOME/.local/bin/guise-token" "$USER_IDENT")" "github_pat_moving"
run_setup_user --store op >/dev/null 2>&1
expect_eq "a move from op-cache to op exits 0" "$?" "0"
: > "$OP_CACHE_LOG"
expect_eq "after which reads go straight to op" \
  "$("$HOME/.local/bin/guise-token" "$USER_IDENT")" "github_pat_moving"
expect "with op-cache out of the path" test ! -s "$OP_CACHE_LOG"
run_setup_user --store op-cache >/dev/null 2>&1
expect_eq "and back into op-cache" "$(cfg identity.$USER_IDENT.keysource)" "op-cache"
run_setup_user >/dev/null 2>&1
expect_eq "a bare re-run keeps op-cache" "$(cfg identity.$USER_IDENT.keysource)" "op-cache"
run_setup_user --store file >/dev/null 2>&1
expect_eq "a move from op-cache to a file exits 0" "$?" "0"
expect "writes the file" test -f "$tokenfile"
expect "and leaves the 1Password item alone" test -f "$OP_FAKE_DIR/Private/patrick-agent/token"
expect_fail "--store takes nothing else" run_setup_user --store keychain

