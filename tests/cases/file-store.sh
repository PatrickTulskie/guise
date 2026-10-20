# --- file key store ----------------------------------------------------------
echo "file key store:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "file-store setup exits 0" "$?" "0"
keyfile="$HOME/.config/guise/keys/$APP_IDENT.pem"
expect "key file written" test -f "$keyfile"
expect_mode "key file mode 600" "$keyfile" "600"
expect_eq "keysource recorded" "$(cfg identity.$APP_IDENT.keysource)" "file"
expect "nothing written to 1Password" test ! -e "$OP_FAKE_DIR/Private/test-agent"
expect "PEM shredded after storing" test ! -e "$SB/key.pem"
t=$("$HOME/.local/bin/guise-token" "$APP_IDENT")
expect_eq "token mints from file key" "${t:0:4}" "ghs_"
run_setup >/dev/null 2>&1
expect_eq "re-run without --store keeps the file store" "$(cfg identity.$APP_IDENT.keysource)" "file"
expect "re-run did not move the key into 1Password" test ! -e "$OP_FAKE_DIR/Private/test-agent"
run_setup --store file --name second >/dev/null 2>&1
expect_eq "second file identity reuses key without --pem" "$?" "0"
expect "second identity got its own key file" test -f "$HOME/.config/guise/keys/second.pem"
"$ROOT/bin/guise" doctor >/dev/null 2>&1
expect_eq "doctor passes with file store" "$?" "0"
FAKE_STAT_GNU=1 "$ROOT/bin/guise" doctor >/dev/null 2>&1
expect_eq "doctor reads app-key permissions with GNU stat semantics" "$?" "0"
"$ROOT/bin/guise" uninstall --yes >/dev/null 2>&1
expect "uninstall keeps key files" test -f "$keyfile"
expect "uninstall removes config file" test ! -e "$HOME/.config/guise/config"
expect "uninstall removes rendered git dir" test ! -e "$HOME/.config/guise/git"

