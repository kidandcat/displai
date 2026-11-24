// Command minerva-webhooks runs on the Minerva desktop (the app bundles and starts it) and
// receives webhooks from third parties at https://<id>.<domain>/<key>/…, through the relay. The
// host name is public (Certificate Transparency logs list it), so the path key is the secret:
// anything else gets a 404 and is neither saved nor reported.
//
// It keeps a tunnel open to the relay (package tunnel), terminates TLS itself with a Let's
// Encrypt certificate for its own host name (obtained and renewed here with ACME TLS-ALPN-01,
// answered through the same tunnel), and reports every request as a JSON line on stdout. The
// relay only ever sees ciphertext and never holds the key.
//
// State lives in -dir: the tunnel secret (the id is derived from it), the ACME account and
// certificates (certs/) and the full requests (inbox/). It exits when stdin closes, so it never
// outlives the app.
//
// Stdout, one JSON object per line:
//
//	{"t":"ready","id":"…","url":"https://…/"}
//	{"t":"tunnel","up":true|false,"error":"…"}
//	{"t":"cert","ok":true|false,"expires":"…","error":"…"}
//	{"t":"webhook","method":"POST","path":"/…" (after the key),"query":"…","headers":{…},"remote":"1.2.3.4",
//	 "body":"…","base64":false,"size":123,"file":"…/inbox/….json"}
package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/acme"
	"golang.org/x/crypto/acme/autocert"

	"github.com/kidandcat/minerva/relay/tunnel"
)

const keepInbox = 200

func main() {
	relay := flag.String("relay", "wss://minerva.kidandcat.com", "relay URL")
	domain := flag.String("domain", "minerva.kidandcat.com", "the webhook host is <id>.<domain>")
	dir := flag.String("dir", "", "state directory (secret, certificates, inbox)")
	acmeURL := flag.String("acme", autocert.DefaultACMEDirectory, "ACME directory (Let's Encrypt staging: https://acme-staging-v02.api.letsencrypt.org/directory)")
	email := flag.String("email", "", "contact email for the ACME account (optional)")
	maxBody := flag.Int64("max-body", 1<<20, "largest request body accepted, in bytes")
	flag.Parse()
	if *dir == "" {
		log.Fatal("-dir is required")
	}
	log.SetPrefix("minerva-webhooks: ")
	if err := os.MkdirAll(filepath.Join(*dir, "inbox"), 0o700); err != nil {
		log.Fatal(err)
	}
	secret, err := loadSecret(filepath.Join(*dir, "secret"))
	if err != nil {
		log.Fatal(err)
	}
	id := tunnel.ID(secret)
	key := tunnel.PathKey(secret)
	host := id + "." + strings.Trim(*domain, ".")
	out := &emitter{enc: json.NewEncoder(os.Stdout)}
	out.emit(map[string]any{"t": "ready", "id": id, "url": "https://" + host + "/" + key + "/"})

	// The app closes our stdin when it quits (or dies).
	go func() {
		_, _ = io.Copy(io.Discard, os.Stdin)
		os.Exit(0)
	}()

	m := &autocert.Manager{
		Prompt:     autocert.AcceptTOS,
		Cache:      autocert.DirCache(filepath.Join(*dir, "certs")),
		HostPolicy: autocert.HostWhitelist(host),
		Email:      *email,
		Client:     &acme.Client{DirectoryURL: *acmeURL},
	}
	tlsConf := m.TLSConfig()
	tlsConf.NextProtos = []string{"http/1.1", acme.ALPNProto}

	ln := tunnel.Listen(*relay, secret)
	var warmOnce sync.Once
	ln.OnState = func(up bool, err error) {
		ev := map[string]any{"t": "tunnel", "up": up}
		if err != nil {
			ev["error"] = err.Error()
		}
		out.emit(ev)
		if up {
			// Get (or load) the certificate now rather than on the first webhook; autocert then
			// renews it on its own before it expires.
			warmOnce.Do(func() { go watchCert(m, host, out) })
		}
	}
	ln.Start()

	h := &handler{key: key, dir: filepath.Join(*dir, "inbox"), maxBody: *maxBody, out: out}
	srv := &http.Server{
		Handler:           h,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       time.Minute,
		WriteTimeout:      time.Minute,
		IdleTimeout:       2 * time.Minute,
		ErrorLog:          log.New(io.Discard, "", 0), // handshake noise from scanners
	}
	log.Fatal(srv.Serve(tls.NewListener(ln, tlsConf)))
}

// loadSecret reads the tunnel secret, creating it the first time.
func loadSecret(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err == nil {
		if s := strings.TrimSpace(string(b)); len(s) >= tunnel.MinSecretLength {
			return s, nil
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	s := tunnel.NewSecret()
	return s, os.WriteFile(path, []byte(s+"\n"), 0o600)
}

// watchCert gets the certificate (retrying with backoff) and reports it, then checks it twice
// a day so a renewal (or a failure to renew) shows up.
func watchCert(m *autocert.Manager, host string, out *emitter) {
	backoff := time.Minute
	for {
		hello := &tls.ClientHelloInfo{
			ServerName:        host,
			SignatureSchemes:  []tls.SignatureScheme{tls.ECDSAWithP256AndSHA256},
			SupportedCurves:   []tls.CurveID{tls.CurveP256},
			CipherSuites:      []uint16{tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256},
			SupportedVersions: []uint16{tls.VersionTLS13, tls.VersionTLS12},
		}
		cert, err := m.GetCertificate(hello)
		if err == nil {
			var leaf *x509.Certificate
			if leaf, err = certLeaf(cert); err == nil {
				out.emit(map[string]any{"t": "cert", "ok": true, "expires": leaf.NotAfter.UTC().Format(time.RFC3339)})
				backoff = time.Minute
				time.Sleep(12 * time.Hour)
				continue
			}
		}
		log.Printf("certificate for %s: %v", host, err)
		out.emit(map[string]any{"t": "cert", "ok": false, "error": err.Error()})
		time.Sleep(backoff)
		backoff = min(backoff*2, 6*time.Hour)
	}
}

func certLeaf(c *tls.Certificate) (*x509.Certificate, error) {
	if c.Leaf != nil {
		return c.Leaf, nil
	}
	if len(c.Certificate) == 0 {
		return nil, errors.New("empty certificate")
	}
	return x509.ParseCertificate(c.Certificate[0])
}

// emitter writes the stdout events, one line each.
type emitter struct {
	mu  sync.Mutex
	enc *json.Encoder
}

func (e *emitter) emit(v any) {
	e.mu.Lock()
	defer e.mu.Unlock()
	_ = e.enc.Encode(v)
}

// handler turns every request into a "webhook" event and answers at once: the assistant acts on
// it later, so the sender only learns that it arrived.
type handler struct {
	key     string // secret first path segment, see [tunnel.PathKey]
	dir     string
	maxBody int64
	out     *emitter
	n       atomic.Int64
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path, ok := strings.CutPrefix(r.URL.Path, "/"+h.key)
	if !ok || path != "" && path[0] != '/' {
		http.NotFound(w, r)
		return
	}
	if path == "" {
		path = "/"
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, h.maxBody))
	if err != nil {
		http.Error(w, "body too large", http.StatusRequestEntityTooLarge)
		return
	}
	ev := map[string]any{
		"t":       "webhook",
		"method":  r.Method,
		"path":    path,
		"query":   r.URL.RawQuery,
		"headers": r.Header,
		"remote":  r.RemoteAddr,
		"size":    len(body),
		"time":    time.Now().UTC().Format(time.RFC3339),
	}
	if utf8.Valid(body) {
		ev["body"], ev["base64"] = string(body), false
	} else {
		ev["body"], ev["base64"] = base64.StdEncoding.EncodeToString(body), true
	}
	if file, err := h.save(ev); err == nil {
		ev["file"] = file
	} else {
		log.Printf("inbox: %v", err)
	}
	h.out.emit(ev)

	// Subscription checks that want their challenge echoed (WebSub, Meta, Strava…).
	if c := r.URL.Query().Get("hub.challenge"); c != "" && r.Method == http.MethodGet {
		w.Header().Set("Content-Type", "text/plain")
		_, _ = io.WriteString(w, c)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = io.WriteString(w, `{"ok":true}`+"\n")
}

// save writes the full request to the inbox (the event the brain gets may be cut short), and
// keeps only the newest [keepInbox] files.
func (h *handler) save(ev map[string]any) (string, error) {
	name := fmt.Sprintf("%s-%d.json", time.Now().UTC().Format("20060102T150405.000"), h.n.Add(1))
	path := filepath.Join(h.dir, name)
	b, err := json.MarshalIndent(ev, "", "  ")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(path, b, 0o600); err != nil {
		return "", err
	}
	if files, err := filepath.Glob(filepath.Join(h.dir, "*.json")); err == nil && len(files) > keepInbox {
		slices.Sort(files)
		for _, f := range files[:len(files)-keepInbox] {
			_ = os.Remove(f)
		}
	}
	return path, nil
}

var _ net.Listener = (*tunnel.Listener)(nil)
