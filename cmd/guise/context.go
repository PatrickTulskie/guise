package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// Codex reads AGENTS.md from the nearest git root down to the working
// directory and never above it, so the one setup drops at the top of the
// workspace is invisible to it. Every other harness walks up the tree and
// finds the file itself. A SessionStart hook hands Codex the file instead: it
// runs `guise context` with the session's cwd on stdin, and whatever lands on
// stdout becomes developer context. Any harness that can run a command at
// session start can use the same subcommand.

// The instructions a session started in dir should carry: the AGENTS.md at
// the top of the workspace it sits under, as edited, or nothing at all. The
// longest root wins, since per-identity workspaces are allowed to nest.
func contextFor(dir string) (string, bool) {
	if !configExists() {
		return "", false
	}
	sep := string(filepath.Separator)
	best := ""
	for _, root := range basedirs() {
		if strings.HasPrefix(dir+sep, root+sep) && len(root) > len(best) {
			best = root
		}
	}
	if best == "" {
		return "", false
	}
	return readFile(filepath.Join(best, "AGENTS.md"))
}

// The directory comes from the hook's JSON on stdin, the way every harness
// hands it over, and is the current one when nothing usable arrives.
func cmdContext(args []string) {
	if len(args) > 0 {
		die("context takes no arguments -- the directory comes from the hook's stdin, otherwise it is the current one")
	}
	dir := cwd()
	if !isTerminal(os.Stdin) {
		raw, _ := io.ReadAll(os.Stdin)
		if d, ok := jsonField(jsonParse(string(raw)), "cwd").(string); ok && d != "" {
			dir = d
		}
	}
	if abs, err := filepath.Abs(dir); err == nil {
		dir = abs
	}
	if text, ok := contextFor(dir); ok {
		_, _ = os.Stdout.WriteString(text)
	}
}

// ---------------------------------------------------------------------------
// The Codex session hook
// ---------------------------------------------------------------------------

func codexHome() string {
	if h := os.Getenv("CODEX_HOME"); h != "" {
		return h
	}
	return filepath.Join(home, ".codex")
}

func codexHooksFile() string { return filepath.Join(codexHome(), "hooks.json") }

// Codex makes its home directory on first run, so the directory is the sign
// of it: the binary alone would have guise write hooks for a Codex nobody has
// signed in to.
func haveCodex() bool { return isDir(codexHome()) }

func codexHookCommand() string { return shellQuote(installedGuise()) + " context" }

// One group holding one handler, the shape Codex reads. Kept stable across
// updates on purpose: Codex ties the trust it is granted to the hook's hash.
func codexHookGroup() map[string]any {
	return map[string]any{
		"hooks": []any{map[string]any{
			"type":          "command",
			"command":       codexHookCommand(),
			"statusMessage": "guise: loading the workspace's AGENTS.md",
		}},
	}
}

// Ours when the command is a program named guise run with the one argument
// context, from whatever install path: a handler that merely contains the
// word is someone else's.
func isGuiseHook(h any) bool {
	c, _ := jsonField(h, "command").(string)
	exe, ok := strings.CutSuffix(c, " context")
	if !ok {
		return false
	}
	base := path.Base(strings.Trim(exe, "'"))
	return base == "guise" || base == "guise.exe"
}

// A group every handler of which is guise's. A hand edit that put another
// handler beside it is left alone, the way a stray marker is.
func isGuiseHookGroup(g any) bool {
	handlers, _ := jsonField(g, "hooks").([]any)
	if len(handlers) == 0 {
		return false
	}
	for _, h := range handlers {
		if !isGuiseHook(h) {
			return false
		}
	}
	return true
}

// hooks.json as an object, or an empty one when there is no file. ok is false
// for a file that is not a JSON object: the lines in it are someone's, so it
// is refused rather than rewritten.
func readCodexHooks() (map[string]any, bool) {
	content, exists := readFile(codexHooksFile())
	if !exists {
		return map[string]any{}, true
	}
	m, ok := jsonParse(content).(map[string]any)
	return m, ok
}

func sessionStartGroups(m map[string]any) []any {
	hooks, _ := m["hooks"].(map[string]any)
	groups, _ := hooks["SessionStart"].([]any)
	return groups
}

func setSessionStartGroups(m map[string]any, groups []any) {
	hooks, _ := m["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
		m["hooks"] = hooks
	}
	if len(groups) == 0 {
		delete(hooks, "SessionStart")
	} else {
		hooks["SessionStart"] = groups
	}
	if len(hooks) == 0 {
		delete(m, "hooks")
	}
}

func withoutGuiseHook(groups []any) (kept []any, found bool) {
	for _, g := range groups {
		if isGuiseHookGroup(g) {
			found = true
			continue
		}
		kept = append(kept, g)
	}
	return kept, found
}

func jsonEqual(a, b any) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return bytes.Equal(x, y)
}

// Not json.Marshal: it would turn the & and < in someone else's hook command
// into \u escapes, and a changed definition is one Codex asks to trust again.
func writeCodexHooks(m map[string]any) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(m); err != nil {
		die("could not encode " + codexHooksFile() + ": " + err.Error())
	}
	mkdirAll(codexHome(), 0o755)
	writeFile(codexHooksFile(), buf.String(), 0o644)
}

// True when the hook is in place afterwards; false on a machine without
// Codex, where there is nothing to do.
func installCodexHook() bool {
	if !haveCodex() {
		return false
	}
	m, ok := readCodexHooks()
	if !ok {
		die(displayPath(codexHooksFile()) + " is not a JSON object, so guise cannot add its session hook to it -- fix the file by hand, then re-run")
	}
	groups := sessionStartGroups(m)
	want := codexHookGroup()
	for _, g := range groups {
		if isGuiseHookGroup(g) && jsonEqual(g, want) {
			return true
		}
	}
	groups, _ = withoutGuiseHook(groups)
	setSessionStartGroups(m, append(groups, want))
	writeCodexHooks(m)
	return true
}

// True when a hook was there to remove. The file goes with it when guise's
// entry was all it held.
func removeCodexHook() bool {
	if !isFile(codexHooksFile()) {
		return false
	}
	m, ok := readCodexHooks()
	if !ok {
		warn("left " + displayPath(codexHooksFile()) + " alone: it is not a JSON object")
		return false
	}
	groups, found := withoutGuiseHook(sessionStartGroups(m))
	if !found {
		return false
	}
	setSessionStartGroups(m, groups)
	if len(m) == 0 {
		_ = os.Remove(codexHooksFile())
		return true
	}
	writeCodexHooks(m)
	return true
}

func chkCodexHook() bool {
	m, ok := readCodexHooks()
	if !ok {
		return false
	}
	want := codexHookGroup()
	for _, g := range sessionStartGroups(m) {
		if isGuiseHookGroup(g) && jsonEqual(g, want) {
			return true
		}
	}
	return false
}
