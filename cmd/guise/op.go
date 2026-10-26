package main

import (
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// Which 1Password account an identity's reads go through. Inside setup, an
// --op-account names the account of the identity setup resolves to (probe:
// the named one, else the default), which is how an identity that never had
// one gets its reads back. Any other identity keeps its own pin: a secret
// reused from it is wherever that identity reads from.
var setupProbe, setupOpAccount string

func opAccountFor(name string) string {
	pinned := cfgGetOr("identity."+name+".opaccount", "")
	if name == setupProbe {
		if setupOpAccount != "" {
			return setupOpAccount
		}
		return pinned
	}
	if pinned != "" {
		return pinned
	}
	return setupOpAccount
}

func opDefaultAccount() string {
	out, err := output("op", "account", "get", "--format", "json")
	if err != nil {
		return ""
	}
	return jsonString(jsonField(jsonParse(out), "id"))
}

func opCmd(account string, args ...string) *exec.Cmd {
	if account != "" {
		args = append([]string{"--account", account}, args...)
	}
	return exec.Command("op", args...)
}

// The field's value, through whichever reader the identity is configured
// with.
func opRead(name, field string) (string, error) { return opReadTo(name, field, os.Stderr) }

func opReadTo(name, field string, stderr io.Writer) (string, error) {
	item, ok := cfgGet("identity." + name + ".opitem")
	if !ok {
		return "", errNoItem
	}
	acct := opAccountFor(name)
	reader := opReader(name)
	if !have(reader) {
		die("missing dependency: " + reader + " -- identity '" + name + "' reads its secret from 1Password through it")
	}
	var cmd *exec.Cmd
	switch {
	case acct == "":
		cmd = exec.Command(reader, "read", item+"/"+field)
	// op-cache hands a command that opens with a flag straight to op,
	// uncached, so the account has to follow the subcommand there.
	case reader == "op-cache":
		cmd = exec.Command("op-cache", "read", "--account", acct, item+"/"+field)
	default:
		cmd = exec.Command("op", "--account", acct, "read", item+"/"+field)
	}
	cmd.Stdin = nil
	cmd.Stderr = stderr
	out, err := cmd.Output()
	return chomp(string(out)), err
}

type opError string

func (e opError) Error() string { return string(e) }

const errNoItem = opError("no 1Password item in config")

func opVersion() string {
	out, err := output("op", "--version")
	if err != nil {
		return ""
	}
	return out
}

func opAtLeast(want string) bool {
	have := opVersion()
	if have == "" {
		return false
	}
	hm, hn, ok := majorMinor(have)
	if !ok {
		return false
	}
	wm, wn, _ := majorMinor(want)
	return hm > wm || (hm == wm && hn >= wn)
}

func majorMinor(v string) (int, int, bool) {
	parts := strings.SplitN(v, ".", 3)
	if len(parts) < 2 {
		return 0, 0, false
	}
	major, err := strconv.Atoi(parts[0])
	if err != nil {
		return 0, 0, false
	}
	minorStr := parts[1]
	for i, c := range minorStr {
		if c < '0' || c > '9' {
			minorStr = minorStr[:i]
			break
		}
	}
	minor, err := strconv.Atoi(minorStr)
	if err != nil {
		return 0, 0, false
	}
	return major, minor, true
}

// --- JSON, the way jq -r would read it ------------------------------------

func jsonParse(s string) any {
	dec := json.NewDecoder(strings.NewReader(s))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil
	}
	return v
}

func jsonField(v any, key string) any {
	m, ok := v.(map[string]any)
	if !ok {
		return nil
	}
	return m[key]
}

func jsonArray(s string) []any {
	a, _ := jsonParse(s).([]any)
	return a
}

// jq -r for the scalars guise reads: a string bare, a number as written, null
// as "null". An object or array is never one of them, so it reads as "".
func jsonString(v any) string {
	switch t := v.(type) {
	case nil:
		return "null"
	case string:
		return t
	case json.Number:
		return t.String()
	case bool:
		if t {
			return "true"
		}
		return "false"
	}
	return ""
}
