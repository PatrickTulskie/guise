# --- commit signing ----------------------------------------------------------
# A separate GitHub account is a real account, so it can hold an SSH signing key
# and GitHub can mark its commits Verified. App identities cannot: there is no
# settings page behind a foo[bot] user.
echo "commit signing (user identity):"
new_sandbox
export FAKE_GH_LOGIN=PatrickTulskie
# The human signs through something like 1Password's op-ssh-sign, which cannot
# use a key file on disk. Nothing below may ever reach it.
printf '#!/bin/sh\necho called >> "%s"\nexit 1\n' "$SB/human-signer.log" > "$SB/human-signer"
chmod +x "$SB/human-signer"
git config --global gpg.ssh.program "$SB/human-signer"
new_token_file "$SB/pat.txt"
run_setup_user --store file --sign --token-file "$SB/pat.txt" >"$SB/sign.out" 2>&1
# Non-zero, and correctly so: the key is not on the account yet, which is a real
# gap doctor has to report. Putting it there is a browser step.
expect_eq "setup ends non-zero while the key is not on the account" "$?" "1"
signkey="$HOME/.config/guise/keys/$USER_IDENT.signing"
expect_eq "signing recorded in config" "$(cfg identity.$USER_IDENT.signing)" "ssh"
expect_eq "signingkey points into the keys dir" "$(cfg identity.$USER_IDENT.signingkey)" "$signkey"
expect "private half generated" test -f "$signkey"
expect "public half written alongside" test -f "$signkey.pub"
expect_mode "private half is mode 600" "$signkey" "600"
expect "an ed25519 key" grep -q '^ssh-ed25519 ' "$signkey.pub"
# Agents roam the workspace; a signing key there is one they could commit.
expect_eq "nothing signing-shaped under the agent workspace" \
  "$(find "$HOME/agentic-code" -name '*.signing*' | wc -l | tr -d ' ')" "0"

# Registering a signing key needs an account-level permission no fine-grained PAT
# can carry, so setup asks rather than tries -- and the whole signing path stays
# credential-free.
expect "setup prints the public key to paste" grep -qF \
  "$(awk '{print $1" "$2}' "$signkey.pub")" "$SB/sign.out"
expect "and names the Signing Key dropdown, not the authentication one" \
  grep -q 'Key type: Signing Key' "$SB/sign.out"
expect_eq "nothing was ever posted to the key API" \
  "$(grep -c '/user/ssh_signing_keys' "$CURL_LOG")" "0"
expect_eq "the registration check is the only failure" \
  "$(agent doctor 2>&1 | grep -c '^  FAIL')" "1"
expect_eq "and it names the account" \
  "$(agent doctor 2>&1 | grep -c "FAIL  signing key registered on @$USER_IDENT")" "1"
expect_eq "while commits already sign and verify locally" \
  "$(agent doctor 2>&1 | grep -c 'ok    commits sign and verify in agent scope')" "1"

signrepo="$HOME/agentic-code/$USER_IDENT/signed"
git init -q "$signrepo"
expect_eq "gpgsign on inside scope" "$(git -C "$signrepo" config --get commit.gpgsign)" "true"
expect_eq "tags sign too" "$(git -C "$signrepo" config --get tag.gpgsign)" "true"
expect_eq "ssh signature format inside scope" "$(git -C "$signrepo" config --get gpg.format)" "ssh"
expect_eq "signing key resolves inside scope" \
  "$(git -C "$signrepo" config --get user.signingkey)" "$(git_path "$signkey")"
expect_eq "human gpgsign untouched outside scope" \
  "$(git -C "$SB" config --get commit.gpgsign)" "true"
expect_fail "and no ssh format leaked into the human's config" \
  git -C "$SB" config --get gpg.format
( cd "$signrepo" && echo x > f && git add f && git commit -q -m "signed commit" )
expect_eq "the commit carries a good signature" \
  "$(git -C "$signrepo" log -1 --format='%G?')" "G"
expect "allowed signers file names the agent's commit email" \
  grep -q "^4444+$USER_IDENT@users\.noreply\.github\.com namespaces=\"git\" ssh-ed25519 " \
  "$HOME/.config/guise/git/$USER_IDENT.allowed_signers"

# A human who signs through 1Password sets gpg.ssh.program globally, and git
# merges config per key -- so the scoped conf has to name its own signer, or
# every agent commit is handed to one that cannot use a key file on disk.
echo "a global ssh signer is not inherited:"
expect "the rendered conf names ssh-keygen" \
  grep -q '^	program = ssh-keygen$' "$HOME/.config/guise/git/$USER_IDENT.conf"
expect_eq "ssh-keygen signs inside scope" \
  "$(git -C "$signrepo" config --get gpg.ssh.program)" "ssh-keygen"
( cd "$signrepo" && echo y > f && git commit -q -am "signed despite the human's signer" )
expect_eq "a commit still carries a good signature" \
  "$(git -C "$signrepo" log -1 --format='%G? %s')" "G signed despite the human's signer"
expect "and the human's signer was never invoked" test ! -e "$SB/human-signer.log"
expect_eq "which still signs for the human outside scope" \
  "$(git -C "$SB" config --get gpg.ssh.program)" "$(git_path "$SB/human-signer")"
# A conf rendered before the program line existed: doctor has to name the
# problem, and update -- not setup -- is what repairs it.
grep -v '^	program = ' "$HOME/.config/guise/git/$USER_IDENT.conf" \
  | sed 's|^	signingkey = .*|	signingkey = key::ssh-ed25519 AAAA|' > "$SB/old.conf"
cat "$SB/old.conf" > "$HOME/.config/guise/git/$USER_IDENT.conf"
expect_eq "doctor names an inherited signer" \
  "$(agent doctor 2>&1 | grep -c 'FAIL  agent scope signs with ssh-keygen')" "1"
expect "and points at update" \
  sh -c "'$ROOT/bin/guise' doctor 2>&1 | grep -A2 'FAIL  agent scope signs with ssh-keygen' | grep -q \"guise update\""
# A literal would send signing to an ssh-agent, which holds the human's keys.
expect_eq "and a signingkey that is not the identity's key file" \
  "$(agent doctor 2>&1 | grep -c "FAIL  agent scope signs with the identity's own key file")" "1"
agent update >/dev/null 2>&1
expect_eq "update re-renders the conf" "$?" "0"
expect_eq "and the signer check passes again" \
  "$(agent doctor 2>&1 | grep -c 'ok    agent scope signs with ssh-keygen')" "1"
expect_eq "as does the key file check" \
  "$(agent doctor 2>&1 | grep -c "ok    agent scope signs with the identity's own key file")" "1"

# Paste the key into the account's signing keys page, the way a human does.
echo "once the key is on the account:"
awk '{print $1" "$2}' "$signkey.pub" >> "$SIGNING_KEYS_FILE"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes" "$?" "0"
FAKE_STAT_GNU=1 agent doctor >/dev/null 2>&1
expect_eq "doctor reads signing-key permissions with GNU stat semantics" "$?" "0"
run_setup_user --login "$USER_IDENT" >"$SB/sign2.out" 2>&1
expect_eq "a bare re-run exits 0 now" "$?" "0"
expect "and says the key is already registered" \
  grep -q "already registered on @$USER_IDENT" "$SB/sign2.out"
expect_eq "and keeps signing on" "$(cfg identity.$USER_IDENT.signing)" "ssh"
# Re-running setup is the advertised repair action: it must not mint a new key,
# since the old public half is the one registered on the account.
fp=$(ssh-keygen -lf "$signkey.pub" | awk '{print $2}')
run_setup_user --login "$USER_IDENT" >/dev/null 2>&1
expect_eq "and reuses the same key" "$(ssh-keygen -lf "$signkey.pub" | awk '{print $2}')" "$fp"

# Signing locally and being Verified on GitHub fail separately, and the checks
# have to tell them apart.
: > "$SIGNING_KEYS_FILE"
agent doctor >/dev/null 2>&1
expect_eq "doctor fails again if the key is removed from the account" "$?" "1"
awk '{print $1" "$2}' "$signkey.pub" >> "$SIGNING_KEYS_FILE"

echo "turning signing back off:"
new_token_file "$SB/pat2.txt"
run_setup_user --name gated --store file --sign --token-file "$SB/pat2.txt" >/dev/null 2>&1
expect "a second signing identity got its own key" \
  test -f "$HOME/.config/guise/keys/gated.signing"
expect_eq "with signing on" "$(cfg identity.gated.signing)" "ssh"
run_setup_user --name gated --no-sign >/dev/null 2>&1
expect_eq "--no-sign exits 0" "$?" "0"
expect_fail "signing unset in config" cfg identity.gated.signing
expect_fail "signingkey unset too" cfg identity.gated.signingkey
expect "local private key shredded" test ! -e "$HOME/.config/guise/keys/gated.signing"
expect "public half removed with it" test ! -e "$HOME/.config/guise/keys/gated.signing.pub"
expect "allowed signers file removed" test ! -e "$HOME/.config/guise/git/gated.allowed_signers"
gatedrepo="$HOME/agentic-code/gated/scoped"
git init -q "$gatedrepo"
expect_eq "gpgsign back off inside scope" \
  "$(git -C "$gatedrepo" config --get commit.gpgsign)" "false"
expect_fail "no ssh signing format left behind" git -C "$gatedrepo" config --get gpg.format
agent doctor --name gated >/dev/null 2>&1
expect_eq "doctor passes with signing off again" "$?" "0"

# Shredding the key before the config stops pointing at it would leave a conf
# that still signs, naming a key that is gone. Force a die after that point --
# the token comes from a file, but storing it needs 1Password.
echo "a --no-sign that dies partway:"
new_token_file "$SB/pat3.txt"
run_setup_user --name opsign --store op --sign --token-file "$SB/pat3.txt" >/dev/null 2>&1
opkey="$HOME/.config/guise/keys/opsign.signing"
expect "an op-store identity gets a signing key too" test -f "$opkey"
new_token_file "$SB/pat4.txt"
OP_FAKE_FORBID=1 run_setup_user --name opsign --no-sign \
  --token-file "$SB/pat4.txt" >/dev/null 2>&1
expect_eq "setup dies when 1Password is unreachable" "$?" "1"
expect "the signing key survived the failure" test -f "$opkey"
expect_eq "and the config still says it signs" "$(cfg identity.opsign.signing)" "ssh"
new_token_file "$SB/pat5.txt"
run_setup_user --name opsign --no-sign --token-file "$SB/pat5.txt" >/dev/null 2>&1
expect_eq "a --no-sign that completes exits 0" "$?" "0"
expect "and only then is the key shredded" test ! -e "$opkey"

echo "signing refusals:"
run_setup --pem "$SB/key.pem" --sign >/dev/null 2>&1
expect_eq "--sign is refused on an app identity" "$?" "1"
expect "and refuses before touching the PEM" test -f "$SB/key.pem"

echo "signing survives rename:"
agent rename "$USER_IDENT" bot-renamed >/dev/null 2>&1
expect_eq "rename exits 0" "$?" "0"
expect_eq "signingkey follows the rename" \
  "$(cfg identity.bot-renamed.signingkey)" "$HOME/.config/guise/keys/bot-renamed.signing"
expect "renamed private key exists" test -f "$HOME/.config/guise/keys/bot-renamed.signing"
expect "renamed public key exists" test -f "$HOME/.config/guise/keys/bot-renamed.signing.pub"
expect "stale allowed signers removed" \
  test ! -e "$HOME/.config/guise/git/$USER_IDENT.allowed_signers"
renamedsign="$HOME/agentic-code/bot-renamed/scoped"
git init -q "$renamedsign"
( cd "$renamedsign" && echo x > f && git add f && git commit -q -m "still signed" )
expect_eq "commits still verify under the new name" \
  "$(git -C "$renamedsign" log -1 --format='%G?')" "G"
# Signing keys are credentials like any other, so uninstall leaves them where
# they are -- same policy as the 1Password items and the on-disk PATs.
agent uninstall --yes >"$SB/uninstall.out" 2>&1
expect "uninstall leaves the signing key alone" \
  test -f "$HOME/.config/guise/keys/bot-renamed.signing"
expect "and names the public half still on the account" \
  grep -q 'public signing key on the agent account' "$SB/uninstall.out"

