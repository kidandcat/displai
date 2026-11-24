package main

import (
	"bufio"
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/kidandcat/minerva/relay/tunnel"
)

const testDomain = "minerva.test"

// selfSigned makes a certificate for host, as the desktop would get from Let's Encrypt.
func selfSigned(t *testing.T, host string) (tls.Certificate, *x509.CertPool) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: host},
		DNSNames:     []string{host},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, _ := x509.ParseCertificate(der)
	pool := x509.NewCertPool()
	pool.AddCert(leaf)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}, pool
}

func TestPeekSNIReplaysTheHello(t *testing.T) {
	host := "abc.minerva.test"
	cert, pool := selfSigned(t, host)
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	defer ln.Close()
	go func() {
		c, err := tls.Dial("tcp", ln.Addr().String(), &tls.Config{ServerName: host, RootCAs: pool})
		if err != nil {
			return
		}
		_, _ = c.Write([]byte("ping"))
		c.Close()
	}()
	c, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	name, hello, err := peekSNI(c)
	if err != nil || name != host {
		t.Fatalf("peekSNI = %q, %v", name, err)
	}
	// Whoever terminates TLS gets the peeked bytes first and completes the handshake.
	srv := tls.Server(&prefixConn{Conn: c, r: io.MultiReader(bytes.NewReader(hello), c)}, &tls.Config{Certificates: []tls.Certificate{cert}})
	got, err := io.ReadAll(srv)
	if err != nil || string(got) != "ping" {
		t.Fatalf("after replay: %q, %v", got, err)
	}
}

func TestPeekSNINotTLS(t *testing.T) {
	a, b := net.Pipe()
	go func() {
		_, _ = a.Write([]byte("GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
		a.Close()
	}()
	name, hello, err := peekSNI(b)
	if name != "" || err == nil || len(hello) == 0 {
		t.Fatalf("plain HTTP: %q %q %v", name, hello, err)
	}
}

type prefixConn struct {
	net.Conn
	r io.Reader
}

func (c *prefixConn) Read(b []byte) (int, error) { return c.r.Read(b) }

func TestIDFor(t *testing.T) {
	p := newPassthrough(testDomain)
	id := tunnel.ID(strings.Repeat("s", 32))
	if got, ok := p.idFor(strings.ToUpper(id) + ".minerva.test."); !ok || got != id {
		t.Fatalf("idFor = %q %v", got, ok)
	}
	for _, name := range []string{testDomain, "x.minerva.test", "a." + id + ".minerva.test", id + ".other.test", ""} {
		if _, ok := p.idFor(name); ok {
			t.Errorf("%q should not route to a desktop", name)
		}
	}
	if len(id) != tunnel.IDLength || !tunnel.ValidID(id) {
		t.Fatalf("bad id %q", id)
	}
}

// relayUnderTest runs the relay's HTTP side and its TLS passthrough listener.
func relayUnderTest(t *testing.T, fallback string) (r *relay, wsURL, tlsAddr string) {
	t.Helper()
	r = newRelay(testDomain)
	r.pass.fallback = fallback
	r.pass.proxyProtocol = fallback != ""
	srv := httptest.NewServer(r.routes())
	t.Cleanup(srv.Close)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go r.pass.serve(ln)
	return r, strings.Replace(srv.URL, "http", "ws", 1), ln.Addr().String()
}

func waitOnline(t *testing.T, l *tunnel.Listener) {
	t.Helper()
	for i := 0; i < 200 && !l.Online(); i++ {
		time.Sleep(10 * time.Millisecond)
	}
	if !l.Online() {
		t.Fatal("tunnel never came up")
	}
}

func TestWebhookThroughTheTunnel(t *testing.T) {
	_, wsURL, tlsAddr := relayUnderTest(t, "")
	secret := tunnel.NewSecret()
	host := tunnel.ID(secret) + "." + testDomain
	cert, pool := selfSigned(t, host)

	// The desktop: TLS ends here, with a key the relay never sees.
	l := tunnel.Listen(wsURL, secret).Start()
	defer l.Close()
	waitOnline(t, l)
	got := make(chan string, 1)
	go http.Serve(tls.NewListener(l, &tls.Config{Certificates: []tls.Certificate{cert}}),
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			b, _ := io.ReadAll(r.Body)
			got <- r.Method + " " + r.URL.Path + " " + string(b) + " from " + r.RemoteAddr
			_, _ = w.Write([]byte("thanks"))
		}))

	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: pool},
		Dial:            func(_, _ string) (net.Conn, error) { return net.Dial("tcp", tlsAddr) },
	}}
	resp, err := client.Post("https://"+host+"/github?x=1", "application/json", strings.NewReader(`{"a":1}`))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != "thanks" {
		t.Fatalf("response %q", body)
	}
	if g := <-got; g != `POST /github {"a":1} from 127.0.0.1` {
		t.Fatalf("desktop got %q", g)
	}

	// An id nobody is connected as: closed at once, no answer.
	other := tunnel.ID(tunnel.NewSecret()) + "." + testDomain
	if _, err := client.Get("https://" + other + "/"); err == nil {
		t.Fatal("offline id should be closed")
	}
}

func TestTunnelNeedsTheSecret(t *testing.T) {
	_, wsURL, _ := relayUnderTest(t, "")
	httpURL := strings.Replace(wsURL, "ws", "http", 1)
	for _, path := range []string{"/tunnel", "/tunnel/accept?c=x"} {
		req, _ := http.NewRequest("GET", httpURL+path, nil)
		req.Header.Set("Authorization", "Bearer short")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s with a short secret: %d", path, resp.StatusCode)
		}
	}
	// A valid secret cannot pick up a connection it was not offered.
	req, _ := http.NewRequest("GET", httpURL+"/tunnel/accept?c=nope", nil)
	req.Header.Set("Authorization", "Bearer "+tunnel.NewSecret())
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("unknown token: %d", resp.StatusCode)
	}
}

func TestOtherNamesGoToTheFallback(t *testing.T) {
	fb, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer fb.Close()
	_, _, tlsAddr := relayUnderTest(t, fb.Addr().String())
	cert, pool := selfSigned(t, testDomain)

	// The fallback (Caddy, in production) reads the PROXY header, then serves TLS itself.
	header := make(chan []byte, 1)
	go func() {
		c, err := fb.Accept()
		if err != nil {
			return
		}
		br := bufio.NewReader(c)
		h := make([]byte, 16+12)
		if _, err := io.ReadFull(br, h); err != nil {
			return
		}
		header <- h
		srv := tls.Server(&prefixConn{Conn: c, r: br}, &tls.Config{Certificates: []tls.Certificate{cert}})
		_, _ = srv.Write([]byte("caddy"))
		srv.Close()
	}()
	c, err := tls.Dial("tcp", tlsAddr, &tls.Config{ServerName: testDomain, RootCAs: pool})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	b, _ := io.ReadAll(c)
	if string(b) != "caddy" {
		t.Fatalf("fallback answered %q", b)
	}
	h := <-header
	if !bytes.HasPrefix(h, []byte("\r\n\r\n\x00\r\nQUIT\n\x21\x11\x00\x0c\x7f\x00\x00\x01")) {
		t.Fatalf("PROXY header % x", h)
	}
}
