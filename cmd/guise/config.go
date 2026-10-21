package main

import (
	"bytes"
	"os"
	"os/exec"
	"sort"
	"strings"
)

// guise's own config is a git config file, read and written through git so
// that a hand edit with `git config -f` and what this tool writes always
// agree on the format. Reads come from one `--list` per invocation; any
// write throws that copy away.

type cfgEntry struct{ key, val string }

var (
	cfgCache  []cfgEntry
	cfgLoaded bool
)

func cfgLoad() []cfgEntry {
	if cfgLoaded {
		return cfgCache
	}
	cfgLoaded = true
	cfgCache = nil
	if _, err := os.Stat(configFile); err != nil {
		return nil
	}
	cmd := exec.Command("git", "config", "-f", configFile, "--list", "--null")
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	for _, rec := range bytes.Split(out, []byte{0}) {
		if len(rec) == 0 {
			continue
		}
		k, v, _ := strings.Cut(string(rec), "\n")
		cfgCache = append(cfgCache, cfgEntry{k, v})
	}
	return cfgCache
}

func cfgInvalidate() { cfgLoaded = false }

// git lowercases the section and the variable, never the subsection in
// between, so a lookup has to spell the key the way --list prints it.
func cfgNorm(key string) string {
	first := strings.Index(key, ".")
	last := strings.LastIndex(key, ".")
	if first < 0 {
		return strings.ToLower(key)
	}
	if first == last {
		return strings.ToLower(key)
	}
	return strings.ToLower(key[:first]) + key[first:last] + strings.ToLower(key[last:])
}

func cfgGet(key string) (string, bool) {
	key = cfgNorm(key)
	val, found := "", false
	for _, e := range cfgLoad() {
		if e.key == key {
			val, found = e.val, true
		}
	}
	return val, found
}

func cfgGetOr(key, def string) string {
	if v, ok := cfgGet(key); ok {
		return v
	}
	return def
}

func cfgHas(key string) bool {
	_, ok := cfgGet(key)
	return ok
}

func cfgGetAll(key string) []string {
	key = cfgNorm(key)
	var vals []string
	for _, e := range cfgLoad() {
		if e.key == key {
			vals = append(vals, e.val)
		}
	}
	return vals
}

// Keys under a prefix such as "identity.<name>.", as --list spells them.
func cfgKeysUnder(prefix string) []string {
	var keys []string
	for _, e := range cfgLoad() {
		if strings.HasPrefix(e.key, prefix) {
			keys = append(keys, e.key)
		}
	}
	return keys
}

func cfgGit(args ...string) error {
	cmd := exec.Command("git", append([]string{"config", "-f", configFile}, args...)...)
	cmd.Stderr = os.Stderr
	err := cmd.Run()
	cfgInvalidate()
	return err
}

func cfgSet(key, val string) {
	if err := cfgGit(key, val); err != nil {
		die("could not write " + key + " to " + configFile)
	}
}

func cfgUnset(key string) {
	cmd := exec.Command("git", "config", "-f", configFile, "--unset", key)
	_ = cmd.Run()
	cfgInvalidate()
}

func cfgUnsetAll(key string) {
	cmd := exec.Command("git", "config", "-f", configFile, "--unset-all", key)
	_ = cmd.Run()
	cfgInvalidate()
}

func cfgAdd(key, val string) {
	if err := cfgGit("--add", key, val); err != nil {
		die("could not write " + key + " to " + configFile)
	}
}

func cfgRenameSection(from, to string) {
	if err := cfgGit("--rename-section", from, to); err != nil {
		die("could not rename " + from + " in " + configFile)
	}
}

func cfgRemoveSection(section string) {
	if err := cfgGit("--remove-section", section); err != nil {
		die("could not remove " + section + " from " + configFile)
	}
}

func configExists() bool {
	_, err := os.Stat(configFile)
	return err == nil
}

func requireConfig() {
	if !configExists() {
		die("no config at " + configFile + " -- run 'guise setup' first")
	}
}

// An identity is anything with an account handle: .slug for app identities,
// .login for user ones.
func listIdentities() []string {
	seen := map[string]bool{}
	var names []string
	for _, e := range cfgLoad() {
		if !strings.HasPrefix(e.key, "identity.") {
			continue
		}
		var name string
		switch {
		case strings.HasSuffix(e.key, ".slug"):
			name = strings.TrimSuffix(strings.TrimPrefix(e.key, "identity."), ".slug")
		case strings.HasSuffix(e.key, ".login"):
			name = strings.TrimSuffix(strings.TrimPrefix(e.key, "identity."), ".login")
		default:
			continue
		}
		if !seen[name] {
			seen[name] = true
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}

// "a b c " -- the form every "(have: ...)" message prints.
func identityList() string {
	s := ""
	for _, n := range listIdentities() {
		s += n + " "
	}
	return s
}

func identityExists(name string) bool {
	return cfgHas("identity."+name+".slug") || cfgHas("identity."+name+".login")
}

// Which identity commands act on when none is named. Set to the first
// identity provisioned; change it with `guise default <name>`. "default" is
// only the fallback for configs written before this was configurable.
func defaultIdentity() string { return cfgGetOr("core.defaultidentity", "default") }

// The configured default, or -- when it names nothing -- the only identity
// there is. Past that there is nothing to guess.
func resolveDefault() (string, bool) {
	name := defaultIdentity()
	if identityExists(name) {
		return name, true
	}
	names := listIdentities()
	if len(names) != 1 {
		return "", false
	}
	return names[0], true
}
