package main

import (
	"crypto/rand"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

func exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

func isFile(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

// Non-empty regular file: test -s.
func isNonEmptyFile(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular() && fi.Size() > 0
}

func isExecutable(p string) bool {
	fi, err := os.Stat(p)
	if err != nil || fi.IsDir() {
		return false
	}
	if runtime.GOOS == "windows" {
		return true
	}
	return fi.Mode().Perm()&0o111 != 0
}

func sameFile(a, b string) bool {
	fa, err := os.Stat(a)
	if err != nil {
		return false
	}
	fb, err := os.Stat(b)
	if err != nil {
		return false
	}
	return os.SameFile(fa, fb)
}

func mkdirAll(p string, mode os.FileMode) {
	if err := os.MkdirAll(p, mode); err != nil {
		die("could not create " + p + ": " + err.Error())
	}
}

func chmod(p string, mode os.FileMode) {
	if err := os.Chmod(p, mode); err != nil && runtime.GOOS != "windows" {
		die("could not chmod " + p + ": " + err.Error())
	}
}

func writeFile(p string, content string, mode os.FileMode) {
	if err := os.WriteFile(p, []byte(content), mode); err != nil {
		die("could not write " + p + ": " + err.Error())
	}
	chmod(p, mode)
}

func readFile(p string) (string, bool) {
	b, err := os.ReadFile(p)
	if err != nil {
		return "", false
	}
	return string(b), true
}

// Git Bash mounts NTFS noacl: chmod is a no-op there and every file reads
// 644, so a mode check can never pass. What keeps keys/ private on Windows is
// the ACL on the profile directory, which doctor names instead of a mode.
func modesApply() bool { return runtime.GOOS != "windows" }

func mode600(p string) bool {
	if !modesApply() {
		return true
	}
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().Perm() == 0o600
}

// Remove a secret's source file once the secret is stored somewhere durable:
// its bytes are written over first, so the contents don't linger on disk.
func shredFile(p string) error {
	fi, err := os.Stat(p)
	if err != nil {
		return err
	}
	if f, err := os.OpenFile(p, os.O_WRONLY, 0); err == nil {
		_, _ = io.CopyN(f, rand.Reader, fi.Size())
		_ = f.Sync()
		_ = f.Close()
	}
	return os.Remove(p)
}

func mustShred(p string) {
	if err := shredFile(p); err != nil {
		die("could not shred " + p + ": " + err.Error())
	}
}

// Resolve a path for comparison: symlinks followed, "." and ".." folded, and
// a tail that does not exist yet carried along. Component by component,
// resolving after each step rather than resolving a prefix and appending the
// rest: ".." has to be applied to what the path before it actually resolved
// to, or a symlink (or a missing directory) earlier in the path changes what
// it means.
func canonicalPath(p string) string {
	sep := string(filepath.Separator)
	rest := filepath.ToSlash(p)
	out := ""
	if filepath.IsAbs(p) {
		out = filepath.VolumeName(p)
		rest = rest[len(out):]
	} else {
		out, _ = os.Getwd()
	}
	for rest != "" {
		rest = strings.TrimLeft(rest, "/")
		comp, remainder, found := strings.Cut(rest, "/")
		if found {
			rest = "/" + remainder
		} else {
			rest = ""
		}
		switch comp {
		case "", ".":
			continue
		case "..":
			// Popping an empty out leaves it empty, which is "/" -- the same
			// place ".." above the root lands.
			if i := strings.LastIndex(out, sep); i >= 0 {
				out = out[:i]
			} else {
				out = ""
			}
		default:
			out = out + sep + comp
		}
		if isDir(out) {
			if real, err := filepath.EvalSymlinks(out); err == nil {
				out = real
			}
		}
	}
	if out == "" {
		out = sep
	}
	return out
}

// A path for git to read out of a file: forward slashes, which native git on
// Windows wants and every other platform spells anyway.
func gitPath(p string) string { return filepath.ToSlash(p) }

func underHome(p string) bool {
	return strings.HasPrefix(p, home+string(filepath.Separator))
}

// ~-form for a path shown to the user.
func tildePath(p string) string {
	if underHome(p) {
		return "~" + filepath.ToSlash(p[len(home):])
	}
	return p
}

// ~-form for values written into git config files.
func displayPath(p string) string {
	if underHome(p) {
		return tildePath(p)
	}
	return gitPath(p)
}

// A path read back out of config, in this platform's spelling.
func cfgPath(key string) (string, bool) {
	v, ok := cfgGet(key)
	if !ok {
		return "", false
	}
	return filepath.FromSlash(v), true
}

func trimTrailingSep(d string) string {
	sep := string(filepath.Separator)
	for d != sep && strings.HasSuffix(d, sep) {
		d = strings.TrimSuffix(d, sep)
	}
	return d
}

// Where an identity's clones live. Per-identity first, so a work identity can
// sit under ~/work while a personal one sits under ~/src; core.basedir is the
// shared fallback. Always answers without a trailing separator.
func basedir(name string) string {
	d := ""
	if name != "" {
		d, _ = cfgPath("identity." + name + ".basedir")
	}
	if d == "" {
		d, _ = cfgPath("core.basedir")
	}
	if d == "" {
		d = defaultBasedir
	}
	return trimTrailingSep(d)
}

// The one directory an identity owns. Basedir "/" is the only case where
// appending needs care.
func identityDir(name string) string {
	base := basedir(name)
	if base == string(filepath.Separator) {
		return base + name
	}
	return base + string(filepath.Separator) + name
}

// Every workspace root in play: the shared one plus any per-identity
// override, each once.
func basedirs() []string {
	roots := []string{basedir("")}
	for _, n := range listIdentities() {
		roots = append(roots, basedir(n))
	}
	return sortUnique(roots)
}

func sortUnique(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	sort.Strings(out)
	return out
}

// Which identity a path belongs to. Longest match wins: per-identity
// workspaces are allowed to nest, so ~/src for one identity and ~/src/agents
// for another both prefix a path under the latter.
func identityOwning(p string) (string, bool) {
	sep := string(filepath.Separator)
	best, bestLen := "", 0
	for _, name := range listIdentities() {
		dir := identityDir(name)
		if strings.HasPrefix(p+sep, dir+sep) && len(dir) > bestLen {
			best, bestLen = name, len(dir)
		}
	}
	return best, best != ""
}

// Standing in an agent directory is a clearer statement of intent than
// whatever the configured default happens to be.
func identityFromCwd() (string, bool) {
	wd, err := os.Getwd()
	if err != nil {
		return "", false
	}
	return identityOwning(wd)
}

func cwd() string {
	wd, _ := os.Getwd()
	return wd
}
