# --- doctor notices a clone that fell out of scope ------------------------------
echo "stranded clones:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
git init -q "$HOME/agentic-code/orphan"
agent doctor > "$SB/stranded.out" 2>&1
expect_eq "a repo outside every identity directory does not fail doctor" "$?" "0"
expect "but doctor warns about it by path" \
  grep -q "$HOME/agentic-code/orphan" "$SB/stranded.out"
rm -rf "$HOME/agentic-code/orphan"
agent doctor > "$SB/stranded.out" 2>&1
expect "and says nothing once it is gone" \
  grep -q "^  ok    no clones stranded" "$SB/stranded.out"

