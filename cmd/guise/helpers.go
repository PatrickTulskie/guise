package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// What the installed helpers do. guise-token prints a GitHub credential for
// an identity: app identities mint (and cache) an installation access token,
// user identities print the stored personal access token. guise-credential
// is the git credential helper the rendered conf names, and guise-gh runs gh
// as the identity owning the current directory.

func dieAs(prog, msg string) {
	fmt.Fprintln(os.Stderr, prog+": "+msg)
	os.Exit(1)
}

// A secret as the helper reads it: a file's contents, or the 1Password
// field, trailing newlines dropped either way.
func helperSecret(identity, field, pathKey string) string {
	const prog = "guise-token"
	source := cfgGetOr("identity."+identity+".keysource", "op")
	if source == "file" {
		path, ok := cfgPath("identity." + identity + "." + pathKey)
		if !ok || !isFile(path) {
			dieAs(prog, "secret file missing for identity '"+identity+"' -- re-run 'guise setup'")
		}
		s, _ := readFile(path)
		return chomp(s)
	}
	if !cfgHas("identity." + identity + ".opitem") {
		dieAs(prog, "no 1Password item in config for '"+identity+"' -- re-run 'guise setup'")
	}
	reader := "op"
	if source == "op-cache" {
		reader = "op-cache"
	}
	if !have(reader) {
		dieAs(prog, reader+" not found -- identity '"+identity+"' reads its secret through it")
	}
	s, err := opRead(identity, field)
	if err != nil {
		os.Exit(exitCode(err))
	}
	return s
}

func helperToken(identity string) { say(tokenFor(identity)) }

func tokenFor(identity string) string {
	const prog = "guise-token"
	if !configExists() {
		dieAs(prog, "no config at "+configFile+" -- run 'guise setup' first")
	}
	// The other helpers pass through whatever they were given (often
	// nothing), so resolving the configured default happens here, once.
	if identity == "" {
		identity = os.Getenv("GUISE_IDENTITY")
	}
	if identity == "" {
		identity = cfgGetOr("core.defaultidentity", "default")
	}

	// A PAT is a standing credential: there is nothing to mint, and caching
	// it would only put a second copy of it on disk.
	if cfgGetOr("identity."+identity+".kind", "app") == "user" {
		return helperSecret(identity, "token", "tokenfile")
	}

	appID, ok := cfgGet("identity." + identity + ".appid")
	if !ok {
		dieAs(prog, "identity '"+identity+"' not in config -- run 'guise setup --name "+identity+"'")
	}
	installID, ok := cfgGet("identity." + identity + ".installationid")
	if !ok {
		dieAs(prog, "identity '"+identity+"' has no installation id -- re-run 'guise setup'")
	}

	mkdirAll(cacheDir, 0o700)
	chmod(cacheDir, 0o700)
	tokenFile := filepath.Join(cacheDir, identity+".token.json")

	// Expiry is self-computed at mint time rather than parsed out of
	// GitHub's expires_at.
	if cached, ok := readFile(tokenFile); ok {
		c := jsonParse(cached)
		exp, _ := strconv.ParseInt(jsonString(jsonField(c, "expires_unix")), 10, 64)
		if exp-time.Now().Unix() > 300 {
			return jsonString(jsonField(c, "token"))
		}
	}

	mintUnix := time.Now().Unix()
	jwt, err := appJWT(helperSecret(identity, "private_key", "keyfile"), appID)
	if err != nil {
		dieAs(prog, "could not sign an app JWT -- the stored key is not a usable RSA key")
	}
	response, err := githubCurl(jwt, "-X", "POST", githubAPI+"/app/installations/"+installID+"/access_tokens")
	if err != nil {
		dieAs(prog, "failed to mint installation token -- key unreadable (1Password locked / file gone), stale ids, or app uninstalled")
	}
	body, ok := jsonParse(response).(map[string]any)
	if !ok {
		dieAs(prog, "GitHub returned no token")
	}
	// Tokens are valid 1h; treat as 55m to stay clear of the boundary.
	body["expires_unix"] = mintUnix + 3300
	out, _ := json.Marshal(body)
	writeFile(tokenFile, string(out)+"\n", 0o600)
	return jsonString(body["token"])
}

// Git credential helper, invoked from agent-scoped git config as:
//
//	guise-credential <identity> <get|store|erase>
//
// Must drain stdin in all cases or git may block on the write side.
func cmdCredential(args []string) {
	identity := ""
	if len(args) >= 2 {
		identity, args = args[0], args[1:]
	}
	op := ""
	if len(args) > 0 {
		op = args[0]
	}
	drain(os.Stdin)
	if op != "get" {
		// store/erase: tokens are ephemeral, nothing to persist.
		return
	}
	fmt.Println("username=x-access-token")
	fmt.Print("password=")
	helperToken(identity)
}

// Identity is inferred from the current directory, overridable with
// GUISE_IDENTITY. gh prefers GH_TOKEN over its stored credentials, so this is
// sufficient. A token that can't be read stops here: gh treats an empty
// GH_TOKEN as unset and would run as whoever is logged in.
func cmdGh(args []string) {
	identity := os.Getenv("GUISE_IDENTITY")
	if identity == "" && configExists() {
		identity, _ = identityFromCwd()
	}
	token := tokenFor(identity)
	if token == "" {
		dieAs("guise-gh", "guise-token returned no token -- refusing to run gh as the logged-in user")
	}
	execReplace("gh", args, envWith("GH_TOKEN", token))
}
