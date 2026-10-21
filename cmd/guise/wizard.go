package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Guided setup. Fills in the flags a flag-driven `setup` would have been
// given, then returns and lets that one path do the work -- so there is one
// provisioning implementation, and the wizard is only a way of answering it.
//
// Everything checkable without the network is checked in a re-ask loop here,
// so a typo costs one prompt instead of the whole run. What is left is the
// GitHub API -- and nothing has been written to disk by the time those calls
// run, so a rejected credential means re-running, not repairing.

var numRe = regexp.MustCompile(`^[0-9]+$`)
var opRefRe = regexp.MustCompile(`^op://[^/]+/[^/]+$`)
var nameRe = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

func expandTilde(p string) string {
	if p == "~" {
		return home
	}
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(home, p[2:])
	}
	return p
}

func wzIntro() {
	wzLine("")
	wzLine(wz.dim + "┌" + wz.off + "  " + wz.inv + " guise " + wz.off + "  " + wz.bold + "Let's give your agent a GitHub identity of its own" + wz.off)
	wzBar()
	wzBar("Its commits will say they came from the agent, with you as co-author,")
	wzBar("and it only gets the access you hand it. A few questions, a browser")
	wzBar("step or two, and one last look before anything is written.")
	wzBar(wz.dim + "^C whenever you like -- nothing changes until you say so." + wz.off)
}

// Signing is on by default in the wizard, which makes this the step most
// runs end on, so it is walked through and checked rather than left to
// doctor.
func wzRegisterSigningKey(login, pubfile string) {
	body := pubkeyBody(pubfile)
	if keyRegistered(login, pubfile) {
		return
	}
	for {
		wzBrowser("Add the signing key to @"+login,
			"Signed in as @"+login+", open "+wzURL("https://github.com/settings/ssh/new"),
			"Key type: Signing Key",
			"Paste this in as the key:",
			" "+body)
		if keyRegistered(login, pubfile) {
			wzBar(wz.green + "Found it -- @" + login + "'s commits will show up Verified." + wz.off)
			return
		}
		again := wzSelect("GitHub doesn't list that key on @"+login+" yet.", []wzOption{
			{"retry", "Check again", ""},
			{"skip", "Skip for now", "commits still sign; doctor nags until it's added"},
		})
		if again == "skip" {
			wzBar(wz.dim + "No problem -- doctor flags it below until it's there." + wz.off)
			return
		}
	}
}

func wzOutro(name string) {
	wzLine("")
	wzLine(wz.green + "◆" + wz.off + "  " + wz.bold + name + " is ready." + wz.off)
	wzBar("Clone something for it:  guise clone <owner/repo>")
	wzBar("Hop into its workspace:  guise use " + name)
	wzLine(wz.dim + "└" + wz.off + "  Happy building.")
}

func (s *setupState) wzAskPem() {
	s.pem = ""
	for {
		s.pem = expandTilde(wzRequire("Path to the downloaded .pem", ""))
		data, err := os.ReadFile(s.pem)
		switch {
		case err != nil || !isFile(s.pem):
			wzWarn("nothing at " + s.pem)
			continue
		case !validPrivateKey(data):
			wzWarn(s.pem + " isn't a private key -- look for the .pem download, not the app page")
			continue
		}
		break
	}
	wzBar(wz.dim + "The .pem gets shredded once its key is stored safely." + wz.off)
}

func (s *setupState) wzAskAppID(def string) {
	for !numRe.MatchString(s.appID) {
		if s.appID != "" {
			wzWarn("the App ID is a number -- not the client ID, and not the app's name")
		}
		s.appID = wzRequire("App ID (top of the app's settings page)", def)
	}
}

func (s *setupState) wzInstallApp() {
	wzBrowser("Install the app on "+s.owner,
		"App settings → Install App → "+s.owner,
		"Pick All repositories, or just the ones the agent works in",
		"If a repo requires signed commits, add the app to its ruleset's bypass list",
		" Settings → Rules → Rulesets → Bypass list → Apps → Always")
}

func (s *setupState) wzAskToken() {
	wzBrowser("Make a token for @"+s.login,
		"Signed in as @"+s.login+", open "+wzURL("https://github.com/settings/tokens/new?scopes=repo&description=guise"),
		"That's a classic token with the repo scope already ticked -- it reaches",
		" any repo @"+s.login+" is added to as a collaborator",
		"Expiration: whatever you'll actually rotate (doctor fails 30 days out)",
		"Generate it and copy the token -- GitHub only shows it once")
	// Straight into this process: never in argv, and never written to disk
	// on the way to being stored.
	tok, ok := wzSecret("Paste the token (it won't show)")
	if !ok {
		die("setup: no token on stdin")
	}
	if tok == "" {
		die("setup: empty token")
	}
	s.wizardToken = tok
}

func (s *setupState) secretNoun() string {
	if s.kind == "user" {
		return "token"
	}
	return "private key"
}

// which: "new" or "op" -- the answer enter picks.
func (s *setupState) wzAskSecret(which string) {
	from := "new"
	newLabel, opLabel := "A new one, made now", "One already in 1Password"
	if s.kind != "user" {
		newLabel = "The .pem GitHub had you download"
	}
	if have("op") {
		q := "Where's the " + s.secretNoun() + "?"
		if which == "op" {
			from = wzSelect(q, []wzOption{{"op", opLabel, "point at the item"}, {"new", newLabel, ""}})
		} else {
			from = wzSelect(q, []wzOption{{"new", newLabel, ""}, {"op", opLabel, "point at the item"}})
		}
	}
	switch {
	case from == "op":
		s.wzAskOpItem()
	case s.kind == "user":
		s.wzAskToken()
	default:
		s.wzAskPem()
	}
}

func (s *setupState) wzAskOpItem() {
	field := "token"
	if s.kind != "user" {
		field = "private_key"
	}
	for {
		s.opItem = ""
		s.opItem = wzRequire("Which item? (op://<vault>/<item>)", "")
		switch {
		case !opRefRe.MatchString(s.opItem):
			wzWarn("that's not op://<vault>/<item>")
		case s.opDoOK("read", s.opItem+"/"+field):
			return
		default:
			wzWarn("can't read a " + field + " field from " + s.opItem + " -- sign in with 'op signin', or check the item")
		}
	}
}

func (s *setupState) wzAskVault() {
	if !have("op") {
		die("the 1Password CLI (op) is not installed -- re-run and choose a file")
	}
	for {
		s.vault = wzRequire("Which 1Password vault?", s.vault)
		if s.opDoOK("vault", "get", s.vault) {
			return
		}
		wzWarn("can't reach vault '" + s.vault + "' -- sign in with 'op signin', or check the name")
	}
}

// Offers the stores this machine can actually serve: a file always,
// 1Password with op on PATH, op-cache with both on PATH. An existing
// identity's store goes first so enter keeps it; a new one leads with the
// file.
func (s *setupState) wzAskStore(current string) {
	cur := current
	if cur == "" {
		cur = "file"
	}
	rec := ""
	if current == "" {
		rec = "recommended · "
	}
	var menu []wzOption
	for _, st := range []string{cur, "file", "op", "op-cache"} {
		if st == cur && len(menu) > 0 {
			continue
		}
		switch st {
		case "file":
			if s.opItem != "" {
				continue
			}
			menu = append(menu, wzOption{"file", "In a file on this machine", rec + "mode 600 under " + displayPath(keysDir)})
		case "op":
			if !have("op") {
				continue
			}
			menu = append(menu, wzOption{"op", "In 1Password", "read on demand · a locked vault pauses the agent"})
		case "op-cache":
			if !have("op") || !have("op-cache") {
				continue
			}
			menu = append(menu, wzOption{"op-cache", "In 1Password, cached by op-cache", "experimental · read once per login · a locked vault doesn't pause the agent"})
		}
	}
	switch {
	case len(menu) == 1 && menu[0].key == "file":
		s.store = "file"
		wzDone("Credential", "a file on this machine (no 1Password CLI found)")
	case len(menu) == 1:
		s.store = menu[0].key
		wzDone("Credential", menu[0].label)
	default:
		s.store = wzSelect("Where should the "+s.secretNoun()+" live?", menu)
	}
}

// Walks an existing identity's settings with what it has now as every
// default, so enter all the way through is a plain re-run. Its name, kind
// and account stay put: those are `rename`, or a new identity.
func (s *setupState) wzEditIdentity(name string) {
	s.name = name
	setupProbe = name
	s.kind = identityKind(name)
	requireDeps(s.kind)

	wzSection(name)
	if s.kind == "app" {
		was := cfgGetOr("identity."+name+".owner", "")
		s.owner = wzRequire("Which account or org is it installed on?", was)
		if s.owner != was {
			s.wzInstallApp()
		}
		was = cfgGetOr("identity."+name+".appid", "")
		s.appID = ""
		s.wzAskAppID(was)
		// The stored key belongs to the App ID it was stored with.
		if s.appID != was || wzYes("Use a new private key?", false) {
			s.wzAskPem()
		} else {
			s.reuse = name
		}
	} else {
		s.login = cfgGetOr("identity."+name+".login", "")
		wzDone("Account", "@"+s.login)
		if wzYes("Paste a new token for @"+s.login+"?", false) {
			s.wzAskToken()
		}
		if wzYes("Sign @"+s.login+"'s commits?", signingEnabled(name)) {
			s.sign = "1"
		} else {
			s.sign = "0"
		}
	}

	// An item moved or renamed in 1Password leaves nothing for a re-run to
	// read.
	if s.wizardToken == "" && s.pem == "" && opBacked(keySource(name)) && !chkOp(name, secretField(name)) {
		wzWarn("can't read " + cfgGetOr("identity."+name+".opitem", "") + " -- moved or renamed in 1Password?")
		s.reuse = ""
		s.wzAskSecret("op")
	}

	s.wzAskStore(keySource(name))
	if opBacked(s.store) && s.opItem == "" {
		was := strings.TrimPrefix(cfgGetOr("identity."+name+".opitem", ""), "op://")
		if was != "" {
			s.vault = strings.SplitN(was, "/", 2)[0]
		}
		was = s.vault
		s.wzAskVault()
		if s.vault != was {
			s.vaultGiven = true
		}
	}

	if defaultIdentity() == name {
		wzDone("Default identity", "yes, already")
	} else if wzYes("Make it your default identity?", false) {
		s.makeDefault = true
	}
}

func (s *setupState) wzReview() {
	wzSection("One last look")
	if s.kind == "app" {
		wzRow("App", s.appID+", installed on "+s.owner)
		switch {
		case s.opItem != "":
			wzRow("Key", "the one in "+s.opItem)
		case s.reuse != "" && s.reuse == s.name:
			wzRow("Key", "keeping the stored one")
		case s.reuse != "":
			wzRow("Key", "reusing the one stored for "+s.reuse)
		default:
			wzRow("Key", displayPath(s.pem)+" "+wz.dim+"(shredded once stored)"+wz.off)
		}
	} else {
		wzRow("Account", "@"+s.login)
		switch {
		case s.tokenFile != "":
			wzRow("Token", s.tokenFile+" "+wz.dim+"(shredded once stored)"+wz.off)
		case s.wizardToken != "":
			wzRow("Token", "the one you just pasted")
		case s.opItem != "":
			wzRow("Token", "the one in "+s.opItem)
		default:
			wzRow("Token", "keeping the one already stored")
		}
		if s.sign == "1" {
			wzRow("Signing", "on, with a key made on this machine")
		} else {
			wzRow("Signing", "off")
		}
	}
	where := s.opItem
	if where == "" {
		where = "vault " + s.vault
	}
	switch s.store {
	case "op":
		wzRow("Stored in", "1Password, "+where)
	case "op-cache":
		wzRow("Stored in", "1Password, "+where+", read through op-cache")
	default:
		wzRow("Stored in", "a file under "+displayPath(keysDir))
	}
	ident := s.name
	if ident == "" {
		ident = s.derived
	}
	wzRow("Identity", ident)
	if s.base != "" {
		dir := s.name
		if dir == "" {
			dir = s.login
		}
		if dir == "" {
			dir = "<app name>"
		}
		wzRow("Clones in", displayPath(s.base)+"/"+dir+"/")
	} else {
		wzRow("Clones in", displayPath(basedir(s.name))+"/"+s.name+"/")
	}
	if s.makeDefault || len(s.existing) == 0 || defaultIdentity() == s.name {
		wzRow("Default", "yes")
	} else {
		wzRow("Default", "no, "+defaultIdentity()+" stays")
	}
	wzBar()
	wzBar(wz.dim + "Writes " + displayPath(configDir) + ", a few helpers in " + displayPath(binDir) + "," + wz.off)
	wzBar(wz.dim + "and one marked block in ~/.gitconfig." + wz.off)
	wzBar()
	if !wzYes("Look good?", true) {
		wzLine(wz.dim + "└" + wz.off + "  No worries -- nothing was written.")
		os.Exit(1)
	}
	wzLine(wz.dim + "└" + wz.off + "  On it.")
	wzLine("")
}

func (s *setupState) wizardSetup() {
	wzInit()
	wzIntro()

	s.existing = listIdentities()
	if len(s.existing) > 0 {
		menu := []wzOption{{"new", "Set up a new identity", ""}}
		for _, n := range s.existing {
			menu = append(menu, wzOption{n, "Review " + n, "walk its settings, keeping whatever you don't change"})
		}
		wzBar()
		var choice string
		if len(s.existing) == 1 {
			choice = wzSelect("You already have "+s.existing[0]+" set up. What's next?", menu)
		} else {
			choice = wzSelect(fmt.Sprintf("You already have %d identities set up. What's next?", len(s.existing)), menu)
		}
		if wz.index != 0 {
			s.wzEditIdentity(choice)
			s.wzReview()
			return
		}
	}

	wzSection("The agent")
	if s.kind != "" {
		wzDone("Kind", s.kind+" (from --kind)")
	} else {
		s.kind = wzSelect("How should your agent show up on GitHub?", []wzOption{
			{"user", "As its own GitHub account", "recommended · works anywhere it's invited, signs commits"},
			{"app", "As a GitHub App bot", "shows up as name[bot] · only where the app is installed"},
		})
	}
	requireDeps(s.kind)

	if s.kind == "app" {
		if !wzYes("Have you created the GitHub App yet?", true) {
			wzBrowser("Create the app",
				"Open "+wzURL("https://github.com/settings/apps/new"),
				"Name it <yourname>-agent -- app names are global, so make it yours",
				"Under Webhook, uncheck Active",
				"Where can it be installed: Any account",
				"Repository permissions: Contents, Pull requests and Issues Read and write,",
				" Checks Read-only, Workflows No access",
				"Create it, then Generate a private key (a .pem downloads) and note the App ID")
		}
		if s.owner == "" {
			s.owner = wzRequire("Which account or org will it be installed on?", "")
		}
		if !numRe.MatchString(s.appID) {
			s.wzAskAppID("")
		}

		// A second installation of an app already set up needs no new key,
		// which is worth offering: the download is one-time-only on GitHub's
		// side.
		s.reuse, _ = findIdentityByAppID(s.appID)
		if s.reuse != "" {
			if wzYes("App "+s.appID+" already has a key stored for "+s.reuse+". Reuse it?", true) {
				s.pem = ""
			} else {
				s.reuse = ""
			}
		}
		if s.opItem != "" {
			wzDone("Key", s.opItem+" (from --op-item)")
		} else if s.reuse == "" && s.pem == "" {
			s.wzAskSecret("new")
		}
		s.wzInstallApp()
	} else {
		if !wzYes("Does the agent have its own GitHub account yet?", true) {
			wzBrowser("Make the agent an account",
				"Sign up at "+wzURL("https://github.com/signup")+" with an email address of its own",
				" GitHub allows one machine account per person, next to your own")
		}
		// Checkable without the network, so it is re-asked like every other
		// local mistake rather than ending the run. A logged-out gh answers
		// nothing, which leaves the real check to cmdSetup once the token
		// names an account.
		human, _ := humanLogin()
		for {
			if s.login == "" {
				s.login = wzRequire("What's the agent account's login?", "")
			}
			if human == "" || lower(s.login) != lower(human) {
				break
			}
			wzWarn("@" + human + " is you -- the agent needs an account of its own")
			s.login = ""
		}

		s.reuse, _ = findIdentityByLogin(s.login)
		switch {
		case s.tokenFile != "":
			wzDone("Token", s.tokenFile+" (from --token-file)")
		case s.opItem != "":
			wzDone("Token", s.opItem+" (from --op-item)")
		case s.reuse != "" && wzYes("A token for @"+s.login+" is already stored. Reuse it?", true):
			// the main path finds it by login, exactly as a bare re-run does
		default:
			s.wzAskSecret("new")
		}
	}

	wzSection("Keeping it safe")
	if s.kind == "user" {
		if s.sign != "" {
			state := "off"
			if s.sign == "1" {
				state = "on"
			}
			wzDone("Signing", state+" (from the flags)")
		} else {
			wzBar("Signed commits show up Verified on GitHub. The key is made here and")
			wzBar("never leaves this machine; its public half goes on @" + s.login + " at the end.")
			if wzYes("Sign @"+s.login+"'s commits?", true) {
				s.sign = "1"
			} else {
				s.sign = "0"
			}
		}
	}

	if s.store != "" {
		wzDone("Credential", s.store+" (from --store)")
	} else {
		s.wzAskStore("")
	}
	if s.opItem == "" && opBacked(s.store) {
		s.wzAskVault()
	}

	wzSection("Where it lives")
	if s.kind == "user" {
		s.derived = s.login
	} else {
		s.derived = "named after the app"
	}
	// Empty is a real answer here: it means "name it after the account",
	// which is what setup does with no --name. The name pattern is checked
	// by cmdSetup either way.
	if s.name == "" {
		var ok bool
		s.name, ok = wzAsk("Name this identity", "", s.derived)
		if !ok {
			die(wz.cmd + ": ran out of input")
		}
	}
	if s.base == "" {
		s.base = wzRequire("Where should its clones live?", displayPath(basedir("")))
	}
	s.base = expandTilde(s.base)

	switch {
	case s.makeDefault:
		wzDone("Default identity", "yes (from --default)")
	case len(s.existing) == 0:
		wzDone("Default identity", "yes, it's your first")
	case wzYes("Make it your default identity?", true):
		s.makeDefault = true
	}

	s.wzReview()
}

// Answers cmdRm's flags, the way wizardSetup answers cmdSetup's. Asks only
// about what is there to remove, and only what a flag has not already
// answered.
func (r *rmState) wzRm() {
	wzInit()
	wzLine("")
	wzLine(wz.dim + "┌" + wz.off + "  " + wz.inv + " guise " + wz.off + "  " + wz.bold + "Remove an identity" + wz.off)
	wzBar(wz.dim + "^C whenever you like -- nothing changes until you say so." + wz.off)

	if r.name == "" {
		wzBar()
		var menu []wzOption
		for _, n := range listIdentities() {
			menu = append(menu, wzOption{n, n, identityAccount(n)})
		}
		if len(menu) == 0 {
			die("no identities in config -- nothing to remove")
		}
		r.name = wzSelect("Which identity?", menu)
	}

	dir := identityDir(r.name)
	clones := len(identityClones(r.name))
	wzSection(r.name)
	wzRow("Account", identityAccount(r.name))
	if opBacked(keySource(r.name)) {
		wzRow("Stored in", "1Password "+wz.dim+"(yours -- guise leaves the item alone)"+wz.off)
	} else {
		wzRow("Stored in", "a file under "+displayPath(keysDir))
	}
	count := fmt.Sprintf("%d clones", clones)
	if clones == 1 {
		count = "1 clone"
	}
	wzRow("Clones in", displayPath(dir)+"/ "+wz.dim+"("+count+")"+wz.off)
	wzBar()

	if !r.keep && !r.code && isDir(dir) {
		if nested, ok := identityNestedIn(r.name); ok {
			wzWarn(nested + " lives inside " + displayPath(dir) + ", so that directory stays.")
		} else {
			unsaved := unsavedClones(r.name)
			if len(unsaved) > 0 {
				wzWarn("These hold work that isn't pushed anywhere:")
				for _, u := range unsaved {
					wzBar("  " + displayPath(u))
				}
			}
			wzBar(wz.dim + "Clones left behind start committing as you." + wz.off)
			if wzYes("Delete "+displayPath(dir)+" and everything in it?", false) {
				r.code = true
			}
		}
	}
	keyfile, _ := secretFile(r.name)
	if !r.keep && !r.secret && keyfile != "" && isFile(keyfile) {
		if wzYes("Shred its stored "+strings.ReplaceAll(secretField(r.name), "_", " ")+"?", true) {
			r.secret = true
		}
	}
	signkey := signingKey(r.name)
	if !r.keep && !r.signing && isFile(signkey) {
		if wzYes("Shred its signing key?", true) {
			r.signing = true
		}
	}

	wzBar()
	if !wzYes("Remove "+r.name+"?", false) {
		wzLine(wz.dim + "└" + wz.off + "  No worries -- nothing was removed.")
		os.Exit(1)
	}
	wzLine(wz.dim + "└" + wz.off + "  On it.")
	wzLine("")
}
