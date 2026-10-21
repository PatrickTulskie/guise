package main

import (
	"os"
	"path/filepath"
	"strings"
)

func lower(s string) string { return strings.ToLower(s) }

// "app" is a GitHub App installation (bot), "user" a real GitHub account with
// a PAT. Configs written before user identities existed have no kind: apps.
func identityKind(name string) string { return cfgGetOr("identity."+name+".kind", "app") }

func isUser(name string) bool { return identityKind(name) == "user" }

func keySource(name string) string { return cfgGetOr("identity."+name+".keysource", "op") }

// "op" and "op-cache" are the same 1Password item; they differ only in what
// answers a read. op asks the vault every time, op-cache remembers the answer
// in memory for the rest of the login session.
func opBacked(store string) bool { return store == "op" || store == "op-cache" }

func opReader(name string) string {
	if keySource(name) == "op-cache" {
		return "op-cache"
	}
	return "op"
}

func secretField(name string) string {
	if isUser(name) {
		return "token"
	}
	return "private_key"
}

func secretFile(name string) (string, bool) {
	if isUser(name) {
		return cfgPath("identity." + name + ".tokenfile")
	}
	return cfgPath("identity." + name + ".keyfile")
}

// PEM (app) or PAT (user), trailing newlines dropped.
func readIdentitySecret(name string) (string, bool) {
	if keySource(name) == "file" {
		path, ok := secretFile(name)
		if !ok || !isFile(path) {
			return "", false
		}
		s, ok := readFile(path)
		return chomp(s), ok
	}
	s, err := opRead(name, secretField(name))
	return s, err == nil
}

// Git identity: bots commit as <slug>[bot], user accounts as themselves. Both
// use GitHub's noreply address so commits link to the account without
// leaking a real mailbox.
func gitName(name string) string {
	if isUser(name) {
		return cfgGetOr("identity."+name+".login", "")
	}
	return cfgGetOr("identity."+name+".slug", "") + "[bot]"
}

func gitEmail(name string) string {
	if isUser(name) {
		return cfgGetOr("identity."+name+".userid", "") + "+" + cfgGetOr("identity."+name+".login", "") + "@users.noreply.github.com"
	}
	return cfgGetOr("identity."+name+".botuserid", "") + "+" + cfgGetOr("identity."+name+".slug", "") + "[bot]@users.noreply.github.com"
}

func findIdentityByAppID(appID string) (string, bool) {
	for _, n := range listIdentities() {
		if cfgGetOr("identity."+n+".appid", "") == appID {
			return n, true
		}
	}
	return "", false
}

func findIdentityByLogin(login string) (string, bool) {
	for _, n := range listIdentities() {
		if l, ok := cfgGet("identity." + n + ".login"); ok && lower(l) == lower(login) {
			return n, true
		}
	}
	return "", false
}

// How GitHub shows the account behind an identity.
func identityAccount(name string) string {
	if isUser(name) {
		return "@" + cfgGetOr("identity."+name+".login", "")
	}
	return cfgGetOr("identity."+name+".slug", "") + "[bot] on " + cfgGetOr("identity."+name+".owner", "")
}

// Commit signing is opt-in, and user identities only: a foo[bot] account has
// no settings page, so nothing can register a signing key against it.
func signingEnabled(name string) bool { return cfgGetOr("identity."+name+".signing", "") == "ssh" }

func signingKey(name string) string {
	if k, ok := cfgPath("identity." + name + ".signingkey"); ok {
		return k
	}
	return filepath.Join(keysDir, name+".signing")
}

func allowedSigners(name string) string { return filepath.Join(renderDir, name+".allowed_signers") }

// "type base64" with the trailing comment dropped -- the form GitHub stores,
// and the only part worth comparing.
func pubkeyBody(file string) string {
	s, _ := readFile(file)
	f := strings.Fields(s)
	if len(f) < 2 {
		return strings.Join(f, " ")
	}
	return f[0] + " " + f[1]
}

// Public and unauthenticated on purpose: a fine-grained PAT scoped to an org
// can never read the account's own key list, so ask GitHub the way anyone
// else would.
func accountSigningKeys(login string) ([]string, bool) {
	body, err := curlGet(githubAPI + "/users/" + login + "/ssh_signing_keys")
	if err != nil {
		return nil, false
	}
	var keys []string
	for _, item := range jsonArray(body) {
		k := jsonString(jsonField(item, "key"))
		f := strings.Fields(k)
		if len(f) >= 2 {
			keys = append(keys, f[0]+" "+f[1])
		}
	}
	return keys, true
}

func keyRegistered(login, pubfile string) bool {
	keys, ok := accountSigningKeys(login)
	if !ok {
		return false
	}
	body := pubkeyBody(pubfile)
	for _, k := range keys {
		if k == body {
			return true
		}
	}
	return false
}

func humanLogin() (string, bool) {
	out, err := output("gh", "api", "user", "--jq", ".login")
	if err != nil || out == "" {
		return "", false
	}
	return out, true
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
