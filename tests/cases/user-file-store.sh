# --- user identity with the file store ---------------------------------------
echo "user identity, file store:"
new_sandbox
printf 'github_pat_filestore\n' > "$SB/pat.txt"
"$ROOT/bin/guise" setup --kind user --store file --token-file "$SB/pat.txt" \
  </dev/null >/dev/null 2>&1
expect_eq "file-store user setup exits 0" "$?" "0"
tokenfile="$HOME/.config/guise/keys/$USER_IDENT.token"
expect "token file written" test -f "$tokenfile"
expect_mode "token file mode 600" "$tokenfile" "600"
expect "nothing written to 1Password" test ! -e "$OP_FAKE_DIR/Private/patrick-agent"
expect_eq "token helper reads the file" \
  "$("$HOME/.local/bin/guise-token" "$USER_IDENT")" "github_pat_filestore"
"$ROOT/bin/guise" doctor >/dev/null 2>&1
expect_eq "doctor passes with a file-stored PAT" "$?" "0"
FAKE_STAT_GNU=1 "$ROOT/bin/guise" doctor >/dev/null 2>&1
expect_eq "doctor reads token permissions with GNU stat semantics" "$?" "0"

# The store is settled only after the identity name is, so an unrelated
# 1Password default can't quietly route a new identity's secret into a vault.
run_setup --store op --default --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "app setup into 1Password as the default exits 0" "$?" "0"
run_setup --name third >/dev/null 2>&1
expect_eq "new identity does not inherit the default's 1Password store" \
  "$(cfg identity.third.keysource)" "file"
expect "new identity's key written to disk" test -f "$HOME/.config/guise/keys/third.pem"
run_setup >/dev/null 2>&1
expect_eq "re-running the app identity keeps 1Password" \
  "$(cfg identity.$APP_IDENT.keysource)" "op"
"$ROOT/bin/guise" setup --kind user </dev/null >/dev/null 2>&1
expect_eq "re-running the user identity keeps its file store" \
  "$(cfg identity.$USER_IDENT.keysource)" "file"

# Moving a file-stored secret into 1Password takes the file with it, but only
# once the move has landed.
OP_FAKE_FORBID=1 "$ROOT/bin/guise" setup --name "$USER_IDENT" --store op \
  --op-account my.1password.com </dev/null >/dev/null 2>&1
expect_eq "a move into an unreachable 1Password fails" "$?" "1"
expect "and leaves the token file in place" test -f "$tokenfile"
"$ROOT/bin/guise" setup --name "$USER_IDENT" --store op \
  --op-account my.1password.com </dev/null >/dev/null 2>&1
expect_eq "a move into 1Password exits 0" "$?" "0"
expect "and shreds the file it moved out of" test ! -e "$tokenfile"
expect_eq "with the token still reading back" \
  "$("$HOME/.local/bin/guise-token" "$USER_IDENT")" "github_pat_filestore"

