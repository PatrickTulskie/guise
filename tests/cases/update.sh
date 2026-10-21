# --- update ------------------------------------------------------------------
# Picking up a new version must work with the vault locked and the network down,
# which is the whole reason this exists instead of "just re-run setup".
echo "update:"
new_sandbox
export FAKE_GH_LOGIN=PatrickTulskie
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
new_token_file "$SB/pat.txt"
run_setup_user --store file --sign --token-file "$SB/pat.txt" >/dev/null 2>&1
awk '{print $1" "$2}' "$HOME/.config/guise/keys/$USER_IDENT.signing.pub" \
  >> "$SIGNING_KEYS_FILE"

confdir="$HOME/.config/guise/git"
cfgfile="$HOME/.config/guise/config"
cfg_before=$(digest < "$cfgfile")
# Clobber everything update owns; leave everything it must not touch alone.
echo broken > "$HOME/.local/bin/guise-gh"
echo broken > "$HOME/.config/guise/hook.sh"
echo broken > "$HOME/.local/bin/guise-token"
echo broken > "$confdir/agent-hooks/prepare-commit-msg"
rm -rf "$confdir/hooks"
echo broken > "$confdir/$APP_IDENT.conf"
echo broken > "$confdir/$USER_IDENT.conf"
# The wiring too, or update could stop calling regen_owned_gitconfig and
# ensure_include_block and every assertion below would still pass. The alias
# stands in for whatever else the engineer keeps in ~/.gitconfig.
echo "# clobbered" > "$HOME/.config/guise/gitconfig"
cat > "$HOME/.gitconfig" <<'GITCONFIG'
[user]
	name = Human
	email = human@example.com
[commit]
	gpgsign = true
[init]
	defaultBranch = main
[alias]
	lg = log --oneline
GITCONFIG
: > "$CURL_LOG"
OP_FAKE_FORBID=1 agent update >/dev/null 2>&1
expect_eq "update exits 0 with 1Password refusing every call" "$?" "0"
expect_eq "and having made no API calls at all" "$(grep -c . "$CURL_LOG")" "0"
expect "guise-gh reinstalled" grep -q GH_TOKEN "$HOME/.local/bin/guise-gh"
expect "token helper reinstalled" grep -q 'guise-token' "$HOME/.local/bin/guise-token"
expect "commit hook reinstalled" grep -q 'Co-authored-by' "$confdir/agent-hooks/prepare-commit-msg"
expect "hook dispatcher reinstalled" test -x "$confdir/hooks/pre-commit"
expect "shell hook reinstalled" grep -q 'emit-shell' "$HOME/.config/guise/hook.sh"
expect_eq "config left byte-identical" "$(digest < "$cfgfile")" "$cfg_before"
# A bare `setup` re-renders only the identity it ran for; update does all of them.
expect "app identity conf re-rendered" \
  grep -q '3333+test-agent\[bot\]@users\.noreply\.github\.com' "$confdir/$APP_IDENT.conf"
expect "user identity conf re-rendered too" \
  grep -q "4444+$USER_IDENT@users\.noreply\.github\.com" "$confdir/$USER_IDENT.conf"
expect "a signing identity still signs afterwards" \
  grep -q 'gpgsign = true' "$confdir/$USER_IDENT.conf"
owned="$HOME/.config/guise/gitconfig"
expect_eq "owned gitconfig regenerated, one includeIf per identity" \
  "$(grep -c includeIf "$owned")" "2"
# A count alone passes when both entries name the same identity, so pair each
# gitdir with the conf it has to load.
for id in "$APP_IDENT" "$USER_IDENT"; do
  expect_eq "the includeIf for '$id' loads its own conf" \
    "$(git config -f "$owned" --get "includeIf.gitdir:~/agentic-code/$id/.path" || echo MISSING)" \
    "git/$id.conf"
done
expect_eq "the managed include block is back in ~/.gitconfig" \
  "$(grep -cF '# >>> guise >>>' "$HOME/.gitconfig")" "1"
expect "unrelated global config survived" grep -q 'lg = log --oneline' "$HOME/.gitconfig"
expect_eq "and the human's own identity with it" \
  "$(git -C "$SB" config --get user.email)" "human@example.com"
wirerepo="$HOME/agentic-code/$APP_IDENT/rewired"
git init -q "$wirerepo"
expect_eq "the identity resolves inside its directory again" \
  "$(git -C "$wirerepo" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"
uprepo="$HOME/agentic-code/$USER_IDENT/afterupdate"
git init -q "$uprepo"
( cd "$uprepo" && echo x > f && git add f && git commit -q -m "after update" )
expect_eq "and commits made after an update still verify" \
  "$(git -C "$uprepo" log -1 --format='%G?')" "G"

# The installed copy is the thing being updated, so prove it actually moves.
echo '# stale' >> "$HOME/.local/bin/guise"
agent update >/dev/null 2>&1
expect "the installed script is replaced by the one being run" \
  cmp -s "$GUISE" "$HOME/.local/bin/guise"
snap_up=$(snapshot)
agent update >/dev/null 2>&1
expect_eq "a second update changes nothing" "$(snapshot)" "$snap_up"
OP_FAKE_FORBID=1 agent doctor >/dev/null 2>&1
expect_eq "doctor still passes after an update" "$?" "0"

expect_fail "update refuses arguments" agent update --name "$APP_IDENT"
rm -f "$cfgfile"
expect_fail "update refuses when there is no config" agent update

