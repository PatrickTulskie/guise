package main

import (
	"os"
	"strings"
)

// git learned SSH signing in 2.34. Older git accepts gpg.format=ssh in config
// and only errors at commit time, long after setup claimed success.
func gitVersion() string {
	out, _ := output("git", "--version")
	f := strings.Fields(out)
	if len(f) >= 3 {
		return f[2]
	}
	return ""
}

func gitSignsSSH() bool {
	major, minor, ok := majorMinor(gitVersion())
	if !ok {
		return false
	}
	return major > 2 || (major == 2 && minor >= 34)
}

// The private half never leaves this machine: generated here, mode 600 under
// the config dir, and regenerated rather than recovered if it is lost.
func generateSigningKey(path, comment string) {
	mkdirAll(keysDir, 0o700)
	chmod(keysDir, 0o700)
	if !isFile(path) {
		_ = os.Remove(path + ".pub")
		// -N '': no passphrase. One the agent cannot type is one it cannot
		// commit with, and the key is worthless off this machine anyway.
		if _, err := output("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", path); err != nil {
			die("ssh-keygen failed to generate " + path)
		}
		say("    generated an ed25519 signing key at " + path)
	} else if !isFile(path + ".pub") {
		// Derive the public half back. Via a temp file: a failed write would
		// leave an empty .pub that the branch above then mistakes for a real
		// one.
		pub, err := output("ssh-keygen", "-y", "-f", path)
		if err != nil {
			die("ssh-keygen could not read " + path)
		}
		writeFile(path+".pub.tmp", pub+"\n", 0o644)
		if err := os.Rename(path+".pub.tmp", path+".pub"); err != nil {
			die("could not write " + path + ".pub")
		}
	}
	chmod(path, 0o600)
}

// Registering a key takes a scope (write:ssh_signing_key) the token is never
// asked to carry, so this asks rather than tries.
func announceSigningKey(login, pubfile string) {
	body := pubkeyBody(pubfile)
	if keyRegistered(login, pubfile) {
		say("    signing key already registered on @" + login)
		return
	}
	say("    one step left, in a browser as @" + login + ":")
	say("      github.com/settings/ssh/new  ->  Key type: Signing Key  ->  paste")
	say("      " + body)
	say("    doctor flags this until you do; commits sign either way, but GitHub")
	say("    shows them Unverified.")
}

// Takes a path, not an identity: callers shred after the config has stopped
// pointing at the key. The public half stays on the account, where only that
// account's owner can remove it, so name it rather than leave it dangling.
func shredSigningKey(key string) {
	if isFile(key + ".pub") {
		say("    remove this key from the agent account's SSH and GPG keys page:")
		say("    " + pubkeyBody(key+".pub"))
		_ = os.Remove(key + ".pub")
	}
	if isFile(key) {
		mustShred(key)
		say("    shredded the local signing key")
	}
}
