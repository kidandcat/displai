package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestHandler(t *testing.T) (*handler, *bytes.Buffer) {
	var buf bytes.Buffer
	return &handler{dir: t.TempDir(), maxBody: 64, out: &emitter{enc: json.NewEncoder(&buf)}}, &buf
}

func TestWebhookEvent(t *testing.T) {
	h, out := newTestHandler(t)
	req := httptest.NewRequest("POST", "/github?x=1", strings.NewReader(`{"action":"opened"}`))
	req.Header.Set("X-GitHub-Event", "issues")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status %d", w.Code)
	}
	var ev struct {
		T, Method, Path, Query, Body, File string
		Base64                             bool
		Headers                            http.Header
	}
	if err := json.Unmarshal(out.Bytes(), &ev); err != nil {
		t.Fatal(err)
	}
	if ev.T != "webhook" || ev.Method != "POST" || ev.Path != "/github" || ev.Query != "x=1" ||
		ev.Body != `{"action":"opened"}` || ev.Base64 || ev.Headers.Get("X-GitHub-Event") != "issues" {
		t.Fatalf("event %+v", ev)
	}
	saved, err := os.ReadFile(ev.File)
	if err != nil || !bytes.Contains(saved, []byte(`opened`)) || filepath.Dir(ev.File) != h.dir {
		t.Fatalf("inbox file %q: %v", ev.File, err)
	}
}

func TestBinaryBodyAndLimits(t *testing.T) {
	h, out := newTestHandler(t)
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("POST", "/", bytes.NewReader([]byte{0xff, 0xfe})))
	var ev struct {
		Body   string
		Base64 bool
	}
	_ = json.Unmarshal(out.Bytes(), &ev)
	if !ev.Base64 || ev.Body != "//4=" {
		t.Fatalf("binary body: %+v", ev)
	}

	out.Reset()
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("POST", "/", strings.NewReader(strings.Repeat("x", 65))))
	if w.Code != http.StatusRequestEntityTooLarge || out.Len() != 0 {
		t.Fatalf("too large: %d, %q", w.Code, out)
	}

	w = httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/favicon.ico", nil))
	if w.Code != http.StatusNotFound || out.Len() != 0 {
		t.Fatalf("favicon: %d", w.Code)
	}
}

func TestEchoesSubscriptionChallenge(t *testing.T) {
	h, _ := newTestHandler(t)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/meta?hub.mode=subscribe&hub.challenge=1234", nil))
	if w.Body.String() != "1234" {
		t.Fatalf("challenge: %q", w.Body)
	}
}

func TestSecretPersists(t *testing.T) {
	path := filepath.Join(t.TempDir(), "secret")
	a, err := loadSecret(path)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := loadSecret(path)
	if a != b || len(a) < 32 {
		t.Fatalf("secret %q then %q", a, b)
	}
	if fi, _ := os.Stat(path); fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode())
	}
}
