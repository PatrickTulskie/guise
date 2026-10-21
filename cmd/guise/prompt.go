package main

import (
	"fmt"
	"os"
	"os/signal"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/term"
)

// The prompts. ask() and askSecret() serve the flag-driven path: they fall
// back to a default, or refuse, when stdin is not a terminal, which is what
// keeps a scripted setup from blocking on a question. The wz_* prompts are
// the wizard's: they read stdin whether or not it is a terminal, because
// there the answers *are* the input, and a pipe is how the suite walks the
// same path a human does.
//
// On a terminal the wizard draws arrow-key menus and redraws each answered
// question in place; from a pipe every answer is one line, and a menu takes
// its key or its number. Everything the wizard draws goes to stderr.

func isTerminal(f *os.File) bool { return term.IsTerminal(int(f.Fd())) }

// Reads up to a newline, a byte at a time the way bash's read does, so
// nothing past the answer is taken from a pipe or a terminal. ok is false at
// EOF, whether or not part of a line came first.
func readLine() (string, bool) {
	var line []byte
	buf := make([]byte, 1)
	for {
		n, err := os.Stdin.Read(buf)
		if n == 1 {
			if buf[0] == '\n' {
				return strings.TrimSuffix(string(line), "\r"), true
			}
			line = append(line, buf[0])
			continue
		}
		if err != nil {
			return string(line), false
		}
	}
}

func ask(prompt, def string) string {
	val := ""
	if isTerminal(os.Stdin) {
		if def != "" {
			fmt.Fprintf(os.Stderr, "%s [%s]: ", prompt, def)
		} else {
			fmt.Fprintf(os.Stderr, "%s: ", prompt)
		}
		val, _ = readLine()
		val = strings.TrimSpace(val)
		if val == "" {
			val = def
		}
	} else {
		val = def
	}
	if val == "" {
		die("missing required value: " + prompt + " (pass it as a flag; run 'guise help')")
	}
	return val
}

// Never echoes and never takes a default -- secrets must not reach argv (and
// therefore ps) or shell history.
func askSecret(prompt string) string {
	if !isTerminal(os.Stdin) {
		die(prompt + ": no value available non-interactively (pass it as a file)")
	}
	fmt.Fprint(os.Stderr, prompt+": ")
	val, _ := readSecretLine()
	fmt.Fprintln(os.Stderr)
	if val == "" {
		die("missing required value: " + prompt)
	}
	return val
}

// --- the wizard's drawing primitives ---------------------------------------

type wizState struct {
	tty   bool
	cols  int
	index int
	cmd   string

	dim, bold, cyan, green, yellow, inv, off string
}

var wz = wizState{cols: 80, cmd: "setup"}

type wzOption struct{ key, label, hint string }

func wzInit() {
	termName := os.Getenv("TERM")
	if termName == "" {
		termName = "dumb"
	}
	// A dumb terminal gets the line-at-a-time prompts a pipe does: every
	// redraw moves the cursor, which it can't.
	if isTerminal(os.Stdin) && isTerminal(os.Stderr) && termName != "dumb" {
		wz.tty = true
		if w, _, err := term.GetSize(int(os.Stdin.Fd())); err == nil && w > 0 {
			wz.cols = w
		}
		// Menus hide the cursor; a ^C mid-menu must not leave it hidden.
		c := make(chan os.Signal, 1)
		signal.Notify(c, os.Interrupt)
		go func() {
			<-c
			restoreTerminal()
			fmt.Fprint(os.Stderr, "\033[?25h")
			os.Exit(130)
		}()
	}
	if isTerminal(os.Stderr) && os.Getenv("NO_COLOR") == "" && termName != "dumb" {
		wz.dim, wz.bold, wz.cyan, wz.green = "\033[2m", "\033[1m", "\033[36m", "\033[32m"
		wz.yellow, wz.inv, wz.off = "\033[33m", "\033[7m", "\033[0m"
	}
}

func wzLine(s string) { fmt.Fprintln(os.Stderr, s) }

func wzBar(s ...string) {
	if len(s) == 0 {
		wzLine(wz.dim + "│" + wz.off)
		return
	}
	wzLine(wz.dim + "│" + wz.off + "  " + strings.Join(s, " "))
}

func wzWarn(s string) { wzBar(wz.yellow + s + wz.off) }

func wzDone(prompt, answer string) {
	wzLine(wz.green + "◇" + wz.off + "  " + prompt + " " + wz.dim + "· " + answer + wz.off)
}

func wzRow(label, val string) { wzBar(wz.dim + fmt.Sprintf("%-11s", label) + wz.off + " " + val) }

func wzSection(title string) {
	wzBar()
	wzLine(wz.dim + "├──" + wz.off + " " + wz.cyan + wz.bold + title + wz.off)
	wzBar()
}

func wzURL(s string) string { return wz.cyan + s + wz.off }

func width(s string) int { return utf8.RuneCountInString(s) }

// Rewrites the prompt line just answered as a settled one. Skipped when the
// line could have wrapped: moving up one row would then clobber the wrong one.
func wzSettle(prompt, answer string, took int) {
	if !wz.tty || took >= wz.cols {
		return
	}
	fmt.Fprint(os.Stderr, "\033[1A\r\033[2K")
	wzDone(prompt, answer)
}

// ok is false at EOF.
func wzAsk(prompt, def, placeholder string) (string, bool) {
	hint := def
	if hint == "" {
		hint = placeholder
	}
	if hint != "" {
		fmt.Fprintf(os.Stderr, "%s◆%s  %s %s(%s)%s › ", wz.cyan, wz.off, prompt, wz.dim, hint, wz.off)
	} else {
		fmt.Fprintf(os.Stderr, "%s◆%s  %s › ", wz.cyan, wz.off, prompt)
	}
	val, ok := readLine()
	if val == "" {
		val = def
	}
	shown := val
	if shown == "" {
		shown = placeholder
	}
	if shown == "" {
		shown = "ok"
	}
	wzSettle(prompt, shown, width(prompt)+width(hint)+width(val)+10)
	return val, ok
}

// Re-asks until there is an answer.
func wzRequire(prompt, def string) string {
	for {
		got, ok := wzAsk(prompt, def, "")
		if !ok {
			die(wz.cmd + ": ran out of input at '" + prompt + "'")
		}
		if got != "" {
			return got
		}
		wzWarn("that one's required")
	}
}

// Hidden on a terminal, plain from a pipe -- there is nothing to hide from a
// pipe, and it is what lets the suite drive this prompt. Never reaches argv.
func wzSecret(prompt string) (string, bool) {
	fmt.Fprintf(os.Stderr, "%s◆%s  %s › ", wz.cyan, wz.off, prompt)
	var val string
	var ok bool
	if isTerminal(os.Stdin) {
		val, ok = readSecretLine()
		fmt.Fprintln(os.Stderr)
	} else {
		val, ok = readLine()
	}
	wzSettle(prompt, "received", width(prompt)+10)
	return val, ok
}

func wzYes(q string, defYes bool) bool {
	yes := defYes
	if wz.tty {
		fmt.Fprint(os.Stderr, "\033[?25l")
		for {
			if yes {
				fmt.Fprintf(os.Stderr, "\r\033[2K%s◆%s  %s  %s● Yes%s %s/ ○ No%s", wz.cyan, wz.off, q, wz.green, wz.off, wz.dim, wz.off)
			} else {
				fmt.Fprintf(os.Stderr, "\r\033[2K%s◆%s  %s  %s○ Yes /%s %s● No%s", wz.cyan, wz.off, q, wz.dim, wz.off, wz.green, wz.off)
			}
			k, ok := readKey()
			if !ok {
				die(wz.cmd + ": ran out of input at '" + q + "'")
			}
			done := false
			switch k {
			case "", " ":
				done = true
			case "y", "Y":
				yes, done = true, true
			case "n", "N":
				yes, done = false, true
			case "h", "l", "\t", "\x1b", "\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D":
				yes = !yes
			}
			if done {
				break
			}
		}
		fmt.Fprint(os.Stderr, "\r\033[2K\033[?25h")
		if yes {
			wzDone(q, "Yes")
		} else {
			wzDone(q, "No")
		}
		return yes
	}
	def := "n"
	if defYes {
		def = "y"
	}
	for {
		ans, ok := wzAsk(q+" (y/n)", def, "")
		if !ok {
			die(wz.cmd + ": ran out of input at '" + q + "'")
		}
		switch lower(ans) {
		case "y", "yes":
			return true
		case "n", "no":
			return false
		}
		wzWarn("answer y or n")
	}
}

// Sets wz.index as well as returning the key, for callers whose keys are
// free text. The first option is the default.
func wzSelect(q string, opts []wzOption) string {
	n := len(opts)
	wzLine(wz.cyan + "◆" + wz.off + "  " + q)
	cur := 0
	if wz.tty {
		fmt.Fprint(os.Stderr, "\033[?25l")
		drawn := false
		for {
			if drawn {
				fmt.Fprintf(os.Stderr, "\033[%dA", n+1)
			}
			drawn = true
			for i, o := range opts {
				fmt.Fprint(os.Stderr, "\r\033[2K")
				switch {
				case i != cur:
					wzLine(wz.dim + "│  ○ " + o.label + wz.off)
				case o.hint != "" && width(o.label)+width(o.hint)+10 < wz.cols:
					wzBar(wz.green + "●" + wz.off + " " + o.label + "  " + wz.dim + o.hint + wz.off)
				default:
					wzBar(wz.green + "●" + wz.off + " " + o.label)
				}
			}
			fmt.Fprint(os.Stderr, "\r\033[2K")
			wzLine(wz.dim + "└  ↑/↓ to move · enter to choose" + wz.off)
			k, ok := readKey()
			if !ok {
				die(wz.cmd + ": ran out of input at '" + q + "'")
			}
			done := false
			switch k {
			case "", " ":
				done = true
			case "k", "\x1b[A":
				cur = (cur + n - 1) % n
			case "j", "\x1b[B":
				cur = (cur + 1) % n
			default:
				if len(k) == 1 && k[0] >= '1' && k[0] <= '9' && int(k[0]-'0') <= n {
					cur = int(k[0]-'0') - 1
				}
			}
			if done {
				break
			}
		}
		fmt.Fprintf(os.Stderr, "\033[%dA\r\033[J\033[?25h", n+2)
	} else {
		for i, o := range opts {
			wzBar(fmt.Sprintf("%d. %s %s[%s]%s", i+1, o.label, wz.dim, o.key, wz.off))
		}
		cur = -1
		for cur < 0 {
			ans, ok := wzAsk("Pick one", opts[0].key, "")
			if !ok {
				die(wz.cmd + ": ran out of input at '" + q + "'")
			}
			for i, o := range opts {
				if lower(ans) == lower(o.key) || ans == fmt.Sprint(i+1) {
					cur = i
					break
				}
			}
			if cur < 0 {
				keys := make([]string, n)
				for i, o := range opts {
					keys[i] = o.key
				}
				wzWarn("pick one of: " + strings.Join(keys, " "))
			}
		}
	}
	wzDone(q, opts[cur].label)
	wz.index = cur
	return opts[cur].key
}

// The steps with no API behind them. Printed as a checklist and waited on
// rather than folded into the narration. Indented lines continue the step
// above them.
func wzBrowser(title string, steps ...string) {
	wzBar()
	wzLine(wz.yellow + "◇" + wz.off + "  " + wz.bold + title + wz.off + " " + wz.dim + "— over to your browser" + wz.off)
	n := 0
	for _, line := range steps {
		if strings.HasPrefix(line, " ") {
			wzBar("  " + line)
		} else {
			n++
			wzBar(fmt.Sprintf("%d. %s", n, line))
		}
	}
	wzBar()
	fmt.Fprintf(os.Stderr, "%s◆%s  Press enter once that's done › ", wz.cyan, wz.off)
	ignored, ok := readLine()
	if !ok {
		die(wz.cmd + ": ran out of input")
	}
	wzSettle("Press enter once that's done", "done", width(ignored)+40)
}

// --- raw-mode reads, for menus and secrets on a terminal -------------------

var rawState *term.State

func enterRaw() bool {
	st, err := term.MakeRaw(int(os.Stdin.Fd()))
	if err != nil {
		return false
	}
	rawState = st
	return true
}

func restoreTerminal() {
	if rawState != nil {
		_ = term.Restore(int(os.Stdin.Fd()), rawState)
		rawState = nil
	}
}

func interrupted() {
	restoreTerminal()
	fmt.Fprint(os.Stderr, "\033[?25h\n")
	os.Exit(130)
}

// One keypress: a byte, or an escape sequence read whole. Enter comes back
// as "", the way `read -n1` reports a newline.
func readKey() (string, bool) {
	if !enterRaw() {
		line, ok := readLine()
		if len(line) > 0 {
			return line[:1], ok
		}
		return "", ok
	}
	defer restoreTerminal()
	buf := make([]byte, 1)
	n, _ := os.Stdin.Read(buf)
	if n == 0 {
		return "", false
	}
	switch buf[0] {
	case 3:
		interrupted()
	case 4:
		return "", false
	case '\r', '\n':
		return "", true
	case 0x1b:
		seq := "\x1b"
		for i := 0; i < 2 && inputReady(time.Second); i++ {
			if n, _ := os.Stdin.Read(buf); n == 1 {
				seq += string(buf[0])
			}
		}
		return seq, true
	}
	return string(buf[0]), true
}

// A line typed without echo.
func readSecretLine() (string, bool) {
	if !enterRaw() {
		return readLine()
	}
	defer restoreTerminal()
	var line []byte
	buf := make([]byte, 1)
	for {
		n, _ := os.Stdin.Read(buf)
		if n == 0 {
			return string(line), false
		}
		switch buf[0] {
		case 3:
			interrupted()
		case 4:
			return string(line), false
		case '\r', '\n':
			return string(line), true
		case 0x7f, 0x08:
			if len(line) > 0 {
				line = line[:len(line)-1]
			}
		default:
			line = append(line, buf[0])
		}
	}
}
