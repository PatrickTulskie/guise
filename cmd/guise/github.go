package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// Every authenticated GitHub call goes through here. The bearer -- a PAT, an
// App JWT, or an installation token -- reaches curl as a config file on
// stdin, never argv, so it never shows in ps.
func githubCurl(bearer string, args ...string) (string, error) {
	all := append([]string{"-sf", "--config", "-",
		"-H", "Accept: application/vnd.github+json",
		"-H", "X-GitHub-Api-Version: 2022-11-28"}, args...)
	cmd := exec.Command("curl", all...)
	cmd.Stdin = strings.NewReader("header = \"Authorization: Bearer " + bearer + "\"\n")
	out, err := cmd.Output()
	return string(out), err
}

func curlGet(url string) (string, error) {
	cmd := exec.Command("curl", "-sf", url)
	cmd.Stdin = nil
	out, err := cmd.Output()
	return string(out), err
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// Any private key openssl would accept; the JWT below needs it to be RSA.
func parsePrivateKey(data []byte) (crypto.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("not a PEM private key")
	}
	if k, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return k, nil
	}
	if k, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		switch k.(type) {
		case *rsa.PrivateKey, *ecdsa.PrivateKey, ed25519.PrivateKey:
			return k, nil
		}
		return k, nil
	}
	if k, err := x509.ParseECPrivateKey(block.Bytes); err == nil {
		return k, nil
	}
	return nil, errors.New("not a private key")
}

func validPrivateKey(data []byte) bool {
	_, err := parsePrivateKey(data)
	return err == nil
}

// An App JWT: RS256 over header.payload, iat backdated 60s for clock skew,
// exp inside the 10 minutes GitHub allows.
func appJWT(pemText, appID string) (string, error) {
	k, err := parsePrivateKey([]byte(pemText))
	if err != nil {
		return "", err
	}
	key, ok := k.(*rsa.PrivateKey)
	if !ok {
		return "", errors.New("the app key is not an RSA key")
	}
	now := time.Now().Unix()
	header := b64url([]byte(`{"typ":"JWT","alg":"RS256"}`))
	payload := b64url([]byte(fmt.Sprintf(`{"iat":%d,"exp":%d,"iss":"%s"}`, now-60, now+540, appID)))
	sum := sha256.Sum256([]byte(header + "." + payload))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	return header + "." + payload + "." + b64url(sig), nil
}
