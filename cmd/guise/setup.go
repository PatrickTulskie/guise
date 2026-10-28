package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type setupState struct {
	owner, appID, pem, name, vault, coauthor, base, store string
	kind, login, tokenFile, opItem                        string
	makeDefault, vaultGiven                               bool
	sign                                                  string // "", "1" or "0"
	wizard                                                string // "", "1" or "0"
	// Set by the wizard only: a token it read from its own prompt, carried in
	// this process rather than through argv or a file on the way to its
	// store.
	wizardToken string
	existing    []string
	reuse       string
	derived     string
}

// openssl is no longer needed for the App JWT, so both kinds want the same
// tools. doctor's dependency check has to stay in step with this list.
func requireDeps(kind string) {
	for _, dep := range []string{"gh", "git", "curl"} {
		if !have(dep) {
			die("missing dependency: " + dep)
		}
	}
}

func (s *setupState) opDoCmd(args ...string) *exec.Cmd {
	return opCmd(opAccountFor(s.name), args...)
}

func (s *setupState) opDoOK(args ...string) bool {
	cmd := s.opDoCmd(args...)
	cmd.Stdin = nil
	return cmd.Run() == nil
}

func (s *setupState) opDoOut(args ...string) (string, error) {
	cmd := s.opDoCmd(args...)
	cmd.Stdin = nil
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	return chomp(string(out)), err
}

func cmdSetup(args []string) {
	s := &setupState{vault: defaultVault}
	argc := len(args)
	need := func(flag string) string {
		if len(args) < 2 {
			die("setup: " + flag + " needs a value")
		}
		v := args[1]
		args = args[2:]
		return v
	}
	for len(args) > 0 {
		switch args[0] {
		case "--kind":
			s.kind = need("--kind")
		// --org is the work checkout's name for the same flag; accept both
		// so one habit works in either repo.
		case "--owner", "--org":
			s.owner = need("--owner")
		case "--app-id":
			s.appID = need("--app-id")
		case "--pem":
			s.pem = need("--pem")
		case "--login":
			s.login = need("--login")
		case "--token-file":
			s.tokenFile = need("--token-file")
		case "--name":
			s.name = need("--name")
		case "--store":
			s.store = need("--store")
		case "--vault":
			s.vault = need("--vault")
			s.vaultGiven = true
		case "--op-account":
			setupOpAccount = need("--op-account")
		case "--op-item":
			s.opItem = need("--op-item")
		case "--coauthor":
			s.coauthor = need("--coauthor")
		case "--base-dir":
			s.base = need("--base-dir")
		case "--default":
			s.makeDefault = true
			args = args[1:]
		case "--wizard":
			s.wizard = "1"
			args = args[1:]
		case "--no-wizard":
			s.wizard = "0"
			args = args[1:]
		case "--sign":
			s.sign = "1"
			args = args[1:]
		case "--no-sign":
			s.sign = "0"
			args = args[1:]
		case "--token":
			die("there is no --token flag on purpose -- argv lands in ps output and shell history; use --token-file, or let setup prompt")
		default:
			die("setup: unknown flag '" + args[0] + "'")
		}
	}

	// A bare `setup` on a terminal has nothing to go on, and dying at the
	// first ask teaches nobody which flags they needed -- so it asks for the
	// answers instead. One flag, or no terminal, and the flag-driven path
	// stands unchanged, which is what keeps scripted installs and CI working.
	if s.wizard == "" && argc == 0 && isTerminal(os.Stdin) {
		s.wizard = "1"
	}
	if s.wizard == "1" {
		s.wizardSetup()
	}

	// Unnamed identities are named after the account once we've discovered it.
	if s.name != "" && !nameRe.MatchString(s.name) {
		die("identity name must match [A-Za-z0-9_-]+: '" + s.name + "'")
	}
	if s.store != "" && s.store != "file" && !opBacked(s.store) {
		die("--store must be 'file', 'op' or 'op-cache', got '" + s.store + "'")
	}
	if s.opItem != "" {
		if !opRefRe.MatchString(s.opItem) {
			die("--op-item takes op://<vault>/<item>, got '" + s.opItem + "'")
		}
		if s.store == "file" {
			die("--op-item names a 1Password item -- it can't go with --store file")
		}
		if !have("op") {
			die("missing dependency: op (--op-item reads from 1Password)")
		}
	}

	// Whose stored settings a re-run may reuse: the named identity, or the
	// default when no name was given (which is the one it would derive anyway).
	setupProbe = s.name
	if setupProbe == "" {
		setupProbe = defaultIdentity()
	}
	probe := setupProbe

	// Flags for one kind mean that kind, and re-running setup for an existing
	// identity keeps its kind; anything else is an account.
	if s.kind == "" {
		switch {
		case s.owner+s.appID+s.pem != "":
			s.kind = "app"
		case s.login+s.tokenFile != "":
			s.kind = "user"
		case identityExists(probe):
			s.kind = identityKind(probe)
		default:
			s.kind = "user"
		}
	}
	if s.kind != "app" && s.kind != "user" {
		die("--kind must be 'app' or 'user', got '" + s.kind + "'")
	}
	if s.kind == "user" {
		if s.owner+s.appID+s.pem != "" {
			die("--owner/--app-id/--pem are app-only; an account identity takes --login and --token-file")
		}
	} else {
		if s.login+s.tokenFile != "" {
			die("--login/--token-file are for an account identity, not an app")
		}
		if s.sign == "1" {
			die("--sign is for account identities -- a foo[bot] account has no settings page to register a signing key on")
		}
	}

	requireDeps(s.kind)

	if s.base != "" {
		s.base = workspacePath(s.base)
	} else if b, ok := cfgPath("core.basedir"); ok {
		s.base = b
	} else {
		s.base = defaultBasedir
	}

	// Optional: when unset, the hook falls back to global user.name/email at
	// commit time, so it tracks the engineer's real config instead of a copy.
	if s.coauthor == "" {
		s.coauthor = cfgGetOr("core.coauthor", "")
	}

	// Filled in by whichever discovery branch runs below. secretItem is the
	// 1Password item the secret was read from, if any, and secretAccount the
	// account it was read through.
	var secretMaterial, secretSource, secretPath, opTitle, secretItem, secretAccount string
	var slug, installID, botUserID, userID, expires string

	if s.kind == "user" {
		// Token: a freshly issued PAT, or one already stored for this identity
		// -- or for any identity using the same account.
		tokenOwner := ""
		switch {
		case s.tokenFile != "":
			data, err := os.ReadFile(s.tokenFile)
			if err != nil || !isFile(s.tokenFile) {
				die("token file not found at " + s.tokenFile)
			}
			secretMaterial = strings.NewReplacer("\r", "", "\n", "").Replace(string(data))
			if secretMaterial == "" {
				die(s.tokenFile + " is empty")
			}
			secretSource = "file"
		case s.wizardToken != "":
			secretMaterial = s.wizardToken
		case s.opItem != "":
			v, err := s.opDoOut("read", s.opItem+"/token")
			if err != nil {
				die("could not read a token field from " + s.opItem + " -- op signin, or check the item")
			}
			secretMaterial = v
			secretItem = s.opItem
			secretAccount = opAccountFor(s.name)
		default:
			if probeLogin, ok := cfgGet("identity." + probe + ".login"); ok && identityKind(probe) == "user" &&
				(s.login == "" || lower(probeLogin) == lower(s.login)) {
				tokenOwner = probe
			} else if s.login != "" {
				tokenOwner, _ = findIdentityByLogin(s.login)
			}
			if tokenOwner != "" {
				v, ok := readIdentitySecret(tokenOwner)
				if !ok {
					die("could not read stored token of identity '" + tokenOwner + "' -- pass --token-file to store a fresh one")
				}
				secretMaterial = v
				secretItem = cfgGetOr("identity."+tokenOwner+".opitem", "")
				secretAccount = opAccountFor(tokenOwner)
			} else {
				secretMaterial = askSecret("Personal access token for the agent account")
			}
		}

		// --- identify the account the token belongs to -----------------------
		say("==> checking the token against GitHub")
		hdr, err := os.CreateTemp("", "guise-hdr")
		if err != nil {
			die("could not create a temp file: " + err.Error())
		}
		hdr.Close()
		userJSON, err := githubCurl(secretMaterial, "-D", hdr.Name(), githubAPI+"/user")
		if err != nil {
			os.Remove(hdr.Name())
			die("GitHub rejected the token -- expired, revoked, or mistyped")
		}
		expires = headerValue(hdr.Name(), "github-authentication-token-expiration")
		os.Remove(hdr.Name())

		user := jsonParse(userJSON)
		acctLogin := jsonString(jsonField(user, "login"))
		userID = jsonString(jsonField(user, "id"))
		if acctLogin == "" || acctLogin == "null" {
			die("GitHub returned no login for this token")
		}
		if userID == "" || userID == "null" {
			die("GitHub returned no user id for this token")
		}
		if s.login != "" && lower(s.login) != lower(acctLogin) {
			die("that token belongs to '" + acctLogin + "', not '" + s.login + "'")
		}
		s.login = acctLogin
		say("    account: " + s.login + " (user id " + userID + ")")
		if expires != "" {
			say("    token expires: " + expires)
		}

		// Separation is the entire point: a token for the human's own account
		// would quietly give the agent the human's identity and access.
		human, ok := humanLogin()
		if !ok {
			warn("could not read your own gh login -- skipped the 'not your own account' check")
		} else if lower(human) == lower(s.login) {
			die("that token belongs to your own account (" + human + ") -- the agent needs an account of its own")
		}

		if s.name == "" {
			s.name = s.login
		}
		opTitle = s.login
		secretPath = filepath.Join(keysDir, s.name+".token")
	} else {
		if identityKind(probe) == "app" && identityExists(probe) {
			if s.owner == "" {
				s.owner = cfgGetOr("identity."+probe+".owner", "")
			}
			if s.appID == "" {
				s.appID = cfgGetOr("identity."+probe+".appid", "")
			}
		}
		if s.owner == "" {
			s.owner = ask("GitHub account (user or org) the app is installed on", "")
		}
		if s.appID == "" {
			s.appID = ask("App ID (top of the app settings page)", "")
		}
		if !numRe.MatchString(s.appID) {
			die("app id must be numeric, got '" + s.appID + "'")
		}

		// Key material: a freshly downloaded PEM, or a key already stored for
		// this identity -- or for ANY identity using the same app, so adding a
		// second installation of one app never needs a new key download.
		keyOwner := ""
		switch {
		case s.pem != "":
			data, err := os.ReadFile(s.pem)
			if err != nil || !isFile(s.pem) {
				die("PEM not found at " + s.pem)
			}
			if !validPrivateKey(data) {
				die(s.pem + " is not a valid private key")
			}
			secretMaterial = chomp(string(data))
			secretSource = "file"
		case s.opItem != "":
			v, err := s.opDoOut("read", s.opItem+"/private_key")
			if err != nil {
				die("could not read a private_key field from " + s.opItem + " -- op signin, or check the item")
			}
			secretMaterial = v
			secretItem = s.opItem
			secretAccount = opAccountFor(s.name)
		default:
			if s.name != "" && cfgGetOr("identity."+s.name+".appid", "") == s.appID {
				keyOwner = s.name
			} else {
				keyOwner, _ = findIdentityByAppID(s.appID)
			}
			if keyOwner == "" {
				die("no --pem given and no stored key for app " + s.appID + " -- pass --pem <downloaded .pem>")
			}
			v, ok := readIdentitySecret(keyOwner)
			if !ok {
				die("could not read stored key of identity '" + keyOwner + "' -- pass --pem to store a fresh one")
			}
			secretMaterial = v
			secretItem = cfgGetOr("identity."+keyOwner+".opitem", "")
			secretAccount = opAccountFor(keyOwner)
		}

		// --- discover slug, installation id, bot user id -----------------------
		say("==> discovering app metadata from GitHub")
		jwt, err := appJWT(secretMaterial, s.appID)
		if err != nil {
			die("could not sign an app JWT with that key: " + err.Error())
		}
		api := func(path string) (string, error) { return githubCurl(jwt, githubAPI+path) }

		appJSON, err := api("/app")
		if err != nil {
			die("GitHub rejected the app JWT -- wrong App ID, or PEM doesn't belong to app " + s.appID)
		}
		app := jsonParse(appJSON)
		slug = jsonString(jsonField(app, "slug"))
		if got := jsonString(jsonField(app, "id")); got != s.appID {
			die("App ID mismatch -- expected " + s.appID + ", API returned " + got)
		}
		say("    app slug: " + slug)

		installs, err := api("/app/installations?per_page=100")
		if err != nil {
			die("could not list installations for the app")
		}
		for _, inst := range jsonArray(installs) {
			if lower(jsonString(jsonField(jsonField(inst, "account"), "login"))) == lower(s.owner) {
				installID = jsonString(jsonField(inst, "id"))
			}
		}
		if installID == "" || installID == "null" {
			die("app '" + slug + "' is not installed on '" + s.owner + "' -- do the install step (see README)")
		}
		say("    installation id: " + installID)

		botJSON, err := curlGet(githubAPI + "/users/" + slug + "%5Bbot%5D")
		if err != nil {
			die("could not resolve bot user " + slug + "[bot]")
		}
		botUserID = jsonString(jsonField(jsonParse(botJSON), "id"))
		if botUserID == s.appID {
			die("bot user id equals app id (" + s.appID + ") -- that can't be right, refusing")
		}
		say("    bot user id: " + botUserID + " (this goes in the commit email, NOT the app id)")

		if s.name == "" {
			s.name = slug
		}
		opTitle = slug
		secretPath = filepath.Join(keysDir, s.name+".pem")
	}

	// A login or slug is already [A-Za-z0-9-] in practice, but this name
	// becomes a directory and a git config key -- check rather than trust.
	if !nameRe.MatchString(s.name) {
		die("can't use '" + s.name + "' as an identity name -- pass --name explicitly")
	}
	name := s.name

	// Deferred until the name is settled: an explicit --store wins, an
	// existing identity keeps the store it already uses (re-running setup is
	// the advertised repair action, so it must not move a secret), and
	// anything new goes to a file.
	if s.store == "" {
		if identityExists(name) {
			s.store = keySource(name)
		} else {
			s.store = "file"
		}
		if s.opItem != "" && !opBacked(s.store) {
			s.store = "op"
		}
	}

	// --- commit signing ---------------------------------------------------------
	// Sticky: a bare re-run keeps doing whatever this identity already does,
	// so only an explicit --sign / --no-sign turns it on or off.
	wantSign, signKey, dropSign := false, "", ""
	switch s.sign {
	case "1":
		wantSign = true
	case "0":
	default:
		wantSign = s.kind == "user" && signingEnabled(name)
	}
	if wantSign {
		if !have("ssh-keygen") {
			die("missing dependency: ssh-keygen (commit signing needs it)")
		}
		if !gitSignsSSH() {
			die("git " + gitVersion() + " is too old for SSH signing -- 2.34 or newer")
		}
		signKey = filepath.Join(keysDir, name+".signing")
		say("==> provisioning an SSH signing key for @" + s.login)
		generateSigningKey(signKey, "guise "+name)
		// The wizard walks this step through once everything else is in place.
		if s.wizard != "1" {
			announceSigningKey(s.login, signKey+".pub")
		}
	} else if signingEnabled(name) {
		// Shredding now would leave a rendered conf that still signs, naming
		// a key that is gone, if anything below this died -- storing the
		// secret can. Shred once the new state is durable, and only after.
		dropSign = signingKey(name)
	}

	// A secret moving into 1Password leaves a file the config no longer
	// tracks. Shredded at the very end, by the same rule as the signing key.
	dropSecret := ""
	if opBacked(s.store) && identityExists(name) && keySource(name) == "file" {
		if f, ok := cfgPath("identity." + name + ".tokenfile"); ok {
			dropSecret = f
		} else if f, ok := cfgPath("identity." + name + ".keyfile"); ok {
			dropSecret = f
		}
	}

	// --- store the secret (1Password or a local file), shred the source ---------
	mkdirAll(configDir, 0o700)
	chmod(configDir, 0o700)
	if opBacked(s.store) {
		if !have("op") {
			die("missing dependency: op (or use --store file to keep the secret on disk)")
		}
		if !opAtLeast(opMinVersion) {
			die("op " + opVersion() + " is too old -- storing a secret without putting it in argv needs " + opMinVersion + " or newer; upgrade op, or use --store file")
		}
		if s.store == "op-cache" && !have("op-cache") {
			die("missing dependency: op-cache (brew install PatrickTulskie/tap/op-cache, or use --store op)")
		}
		// Unpinned, every read goes to whichever account op defaults to, and
		// signing in to a second account can change that answer out from
		// under the item.
		setupOpAccount = opAccountFor(name)
		if setupOpAccount == "" {
			setupOpAccount = opDefaultAccount()
		}
		// A re-run leaves the item where it is: only --vault or --op-item moves it.
		if s.opItem == "" && !s.vaultGiven {
			s.opItem = cfgGetOr("identity."+name+".opitem", "")
		}
		if s.opItem != "" {
			ref := strings.TrimPrefix(s.opItem, "op://")
			s.vault, opTitle, _ = strings.Cut(ref, "/")
		} else {
			s.opItem = "op://" + s.vault + "/" + opTitle
		}
		// Not `op whoami`: it reports session-token state and fails under the
		// desktop app's biometric integration even when real operations work.
		if !s.opDoOK("vault", "get", s.vault) {
			die("1Password vault '" + s.vault + "' unreachable -- not signed in (op signin / enable CLI integration) or the vault doesn't exist")
		}
		// Only the public fields go in as assignments: those are argv, and ps
		// shows argv to every process the same user runs -- the agent included.
		var opFields []string
		opSecretField := "private_key"
		if s.kind == "user" {
			opFields = []string{"login[text]=" + s.login}
			opSecretField = "token"
		} else {
			opFields = []string{"app_id[text]=" + s.appID, "installation_id[text]=" + installID}
		}
		// The same path in another account is a different item, or none at all.
		readVia := secretAccount
		if readVia == "" {
			readVia = opDefaultAccount()
		}
		if s.opItem == secretItem && setupOpAccount == readVia {
			say("==> using the credentials already in 1Password (" + s.opItem + ")")
		} else {
			say("==> storing credentials in 1Password (" + s.opItem + ")")
			if s.opDoOK("item", "get", opTitle, "--vault", s.vault) {
				if _, err := s.opDoOut(append([]string{"item", "edit", opTitle, "--vault", s.vault}, opFields...)...); err != nil {
					die("1Password refused to update " + s.opItem)
				}
			} else {
				if _, err := s.opDoOut(append([]string{"item", "create", "--category", "API Credential", "--title", opTitle, "--vault", s.vault}, opFields...)...); err != nil {
					die("1Password refused to create " + s.opItem)
				}
			}
			s.opStoreSecret(opTitle, opSecretField, secretMaterial)
			back, err := s.opDoOut("read", s.opItem+"/"+opSecretField)
			if err != nil || back != secretMaterial {
				die("1Password readback failed for " + s.opItem + "/" + opSecretField)
			}
		}
		// op-cache remembers a reference until its daemon exits and can't
		// forget just one, so a rotated secret would otherwise keep answering
		// as the old one for the rest of the session.
		if s.store == "op-cache" {
			_, _ = output("op-cache", "clear")
		}
		secretPath = ""
	} else {
		// Deliberately under ~/.config, NOT the agent workspace -- agents roam
		// the workspace and must not be able to read or commit the secret.
		say("==> storing secret at " + secretPath)
		mkdirAll(keysDir, 0o700)
		chmod(keysDir, 0o700)
		writeFile(secretPath, secretMaterial+"\n", 0o600)
	}

	if secretSource == "file" {
		src := s.pem
		if s.kind == "user" {
			src = s.tokenFile
		}
		if !sameFile(src, secretPath) {
			mustShred(src)
			say("    secret stored and the file it came from shredded")
		}
	}

	// --- write config + render everything ---------------------------------------
	say("==> writing config and git wiring")
	if !exists(configFile) {
		writeFile(configFile, "", 0o600)
	}
	chmod(configFile, 0o600)
	cfgSet("core.basedir", gitPath(s.base))
	if s.coauthor != "" {
		cfgSet("core.coauthor", s.coauthor)
	}
	if setupOpAccount != "" {
		cfgSet("identity."+name+".opaccount", setupOpAccount)
	}
	cfgSet("identity."+name+".kind", s.kind)
	if s.kind == "user" {
		cfgSet("identity."+name+".login", s.login)
		cfgSet("identity."+name+".userid", userID)
		if expires != "" {
			cfgSet("identity."+name+".tokenexpires", expires)
		} else {
			cfgUnset("identity." + name + ".tokenexpires")
		}
	} else {
		cfgSet("identity."+name+".owner", s.owner)
		cfgSet("identity."+name+".appid", s.appID)
		cfgSet("identity."+name+".slug", slug)
		cfgSet("identity."+name+".installationid", installID)
		cfgSet("identity."+name+".botuserid", botUserID)
	}
	cfgSet("identity."+name+".keysource", s.store)
	if opBacked(s.store) {
		cfgSet("identity."+name+".opitem", s.opItem)
		cfgUnset("identity." + name + ".keyfile")
		cfgUnset("identity." + name + ".tokenfile")
	} else {
		if s.kind == "user" {
			cfgSet("identity."+name+".tokenfile", gitPath(secretPath))
		} else {
			cfgSet("identity."+name+".keyfile", gitPath(secretPath))
		}
		cfgUnset("identity." + name + ".opitem")
	}
	if wantSign {
		cfgSet("identity."+name+".signing", "ssh")
		cfgSet("identity."+name+".signingkey", gitPath(signKey))
	} else {
		cfgUnset("identity." + name + ".signing")
		cfgUnset("identity." + name + ".signingkey")
	}
	// The first identity provisioned becomes the default; later ones don't
	// steal it unless asked to.
	if s.makeDefault {
		cfgSet("core.defaultidentity", name)
	} else if !cfgHas("core.defaultidentity") {
		cfgSet("core.defaultidentity", name)
	}

	installBinaries()
	installHook()
	installShellHook()
	renderIdentityConf(name)
	regenOwnedGitconfig()
	ensureIncludeBlock()
	if dropSign != "" {
		say("==> commit signing is now off for identity '" + name + "'")
		shredSigningKey(dropSign)
	}
	if dropSecret != "" && isFile(dropSecret) {
		mustShred(dropSecret)
		say("    shredded " + displayPath(dropSecret) + ", now that the secret is in 1Password")
	}
	mkdirAll(identityDir(name), 0o755)
	installAgentDocs(basedir(name))
	// Last: a hooks.json that can't be parsed stops here, with everything
	// else already in place.
	codexHook := installCodexHook()

	say("==> setup complete for identity '" + name + "'")
	if wantSign {
		say("    commits are SSH-signed with " + signKey)
	}
	say("    agent clones go in " + identityDir(name) + "/ (use 'guise clone <owner/repo>')")
	say("    default identity: " + defaultIdentity())
	if codexHook {
		say("    Codex: a session hook in " + displayPath(codexHooksFile()) + " feeds it the workspace's AGENTS.md")
		say("    -- trust it once with /hooks inside codex")
	}
	if rc, ok := shellRc(); ok {
		say("    'guise use' cds this shell once " + displayPath(rc) + " is reloaded")
		say("    -- open a new shell, or: . " + displayPath(rc))
	}
	pathCallout()
	say("")
	if s.wizard != "1" {
		cmdDoctor([]string{"--name", name})
		return
	}
	if wantSign {
		wzRegisterSigningKey(s.login, signKey+".pub")
	}
	cmdDoctor([]string{"--name", name})
	wzOutro(name)
}

// The secret itself goes through a JSON template on op's stdin: the item as
// it is, revealed so its other concealed fields come back intact, with the
// one field set or added.
func (s *setupState) opStoreSecret(title, field, value string) {
	raw, err := s.opDoOut("item", "get", title, "--vault", s.vault, "--format", "json", "--reveal")
	if err != nil {
		die("could not read " + s.opItem + " back from 1Password to set its " + field + " field")
	}
	item, ok := jsonParse(raw).(map[string]any)
	if !ok {
		die("could not read " + s.opItem + " back from 1Password to set its " + field + " field")
	}
	fields, _ := item["fields"].([]any)
	found := false
	for i, f := range fields {
		m, ok := f.(map[string]any)
		if ok && jsonString(m["label"]) == field {
			m["type"] = "CONCEALED"
			m["value"] = value
			fields[i] = m
			found = true
		}
	}
	if !found {
		fields = append(fields, map[string]any{"id": field, "label": field, "type": "CONCEALED", "value": value})
	}
	item["fields"] = fields
	template, err := json.Marshal(item)
	if err != nil {
		die("could not build a 1Password template for " + s.opItem)
	}
	cmd := s.opDoCmd("item", "edit", title, "--vault", s.vault)
	cmd.Stdin = strings.NewReader(string(template))
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		die("1Password refused the " + field + " field on " + s.opItem)
	}
}

// The last value of a response header, split on the first colon only -- the
// value is a timestamp full of them.
func headerValue(file, name string) string {
	content, _ := readFile(file)
	val := ""
	for _, line := range strings.Split(strings.ReplaceAll(content, "\r", ""), "\n") {
		k, v, ok := strings.Cut(line, ":")
		if ok && lower(k) == lower(name) {
			val = strings.TrimSpace(v)
		}
	}
	return val
}
