# --- doctor notices a clone that fell out of scope ------------------------------
echo "stranded clones:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
git init -q "$HOME/agentic-code/orphan"
agent doctor > "$SB/stranded.out" 2>&1
expect_eq "a repo outside every identity directory does not fail doctor" "$?" "0"
expect "but doctor warns about it by path" \
  grep -qF "$(native "$HOME/agentic-code/orphan")" "$SB/stranded.out"
rm -rf "$HOME/agentic-code/orphan"
agent doctor > "$SB/stranded.out" 2>&1
expect "and says nothing once it is gone" \
  grep -q "^  ok    no clones stranded" "$SB/stranded.out"

# No depth limit: a clone any distance under the root is just as unscoped.
git init -q "$HOME/agentic-code/old/team/deep/repo"
git init -q "$HOME/agentic-code/old/team/deep/repo/vendor/inner"
git init -q "$HOME/agentic-code/$APP_IDENT/a/b/c/scoped"
agent doctor > "$SB/stranded.out" 2>&1
expect "doctor finds a stray clone deep under the workspace" \
  grep -qF "$(native "$HOME/agentic-code/old/team/deep/repo") " "$SB/stranded.out"
expect_fail "but not what sits inside it" grep -qF "$(native vendor/inner)" "$SB/stranded.out"
expect_fail "nor anything inside an identity directory" grep -qF "$(native a/b/c/scoped)" "$SB/stranded.out"
