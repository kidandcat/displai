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
	"time"
)

func newTestHandler(t *testing.T) (*handler, *bytes.Buffer) {
	var buf bytes.Buffer
	hooks := filepath.Join(t.TempDir(), "hooks.json")
	writeHooks(t, hooks, hook{Name: "github", Key: "k3ysecretk3ysecret"})
	return &handler{hooks: &registry{path: hooks}, dir: t.TempDir(), maxBody: 64, out: &emitter{enc: json.NewEncoder(&buf)}}, &buf
}

func writeHooks(t *testing.T, path string, hooks ...hook) {
	t.Helper()
	b, _ := json.Marshal(registryFile{Webhooks: hooks})
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, path); err != nil {
		t.Fatal(err)
	}
}

func TestWebhookEvent(t *testing.T) {
	h, out := newTestHandler(t)
	req := httptest.NewRequest("POST", "/k3ysecretk3ysecret/github?x=1", strings.NewReader(`{"action":"opened"}`))
	req.Header.Set("X-GitHub-Event", "issues")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status %d", w.Code)
	}
	var ev struct {
		T, Webhook, Method, Path, Query, Body, File string
		Base64                                      bool
		Headers                                     http.Header
	}
	if err := json.Unmarshal(out.Bytes(), &ev); err != nil {
		t.Fatal(err)
	}
	if ev.T != "webhook" || ev.Webhook != "github" || ev.Method != "POST" || ev.Path != "/github" || ev.Query != "x=1" ||
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
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("POST", "/k3ysecretk3ysecret", bytes.NewReader([]byte{0xff, 0xfe})))
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
	h.ServeHTTP(w, httptest.NewRequest("POST", "/k3ysecretk3ysecret/", strings.NewReader(strings.Repeat("x", 65))))
	if w.Code != http.StatusRequestEntityTooLarge || out.Len() != 0 {
		t.Fatalf("too large: %d, %q", w.Code, out)
	}

}

// The host name is public (Certificate Transparency); scanners must not reach the assistant.
func TestRequestsWithoutThePathKeyAreIgnored(t *testing.T) {
	h, out := newTestHandler(t)
	for _, p := range []string{"/", "/.env", "/github", "/k3ysecretk3ysecretx/github", "/K3Y/github", "/x/k3y/github"} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("POST", p, strings.NewReader("{}")))
		if w.Code != http.StatusNotFound {
			t.Fatalf("%s: status %d", p, w.Code)
		}
	}
	if files, _ := os.ReadDir(h.dir); out.Len() != 0 || len(files) != 0 {
		t.Fatalf("reported %q, saved %d files", out, len(files))
	}
}

func TestEchoesSubscriptionChallenge(t *testing.T) {
	h, _ := newTestHandler(t)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/k3ysecretk3ysecret/meta?hub.mode=subscribe&hub.challenge=1234", nil))
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

// Crawlers find the host in Certificate Transparency logs: a GET or HEAD without a body is
// answered but not saved or reported, unless it is a subscription check.
func TestBodilessGetsAreNoise(t *testing.T) {
	h, out := newTestHandler(t)
	for _, req := range []*http.Request{
		httptest.NewRequest("GET", "/k3ysecretk3ysecret", nil),
		httptest.NewRequest("GET", "/k3ysecretk3ysecret/", nil),
		httptest.NewRequest("HEAD", "/k3ysecretk3ysecret/", nil),
		httptest.NewRequest("GET", "/k3ysecretk3ysecret/storage/logs/laravel.log", nil),
		httptest.NewRequest("GET", "/k3ysecretk3ysecret/wp-admin/setup.php?step=1", nil),
		httptest.NewRequest("GET", "/k3ysecretk3ysecret/.env", nil),
	} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if w.Code != http.StatusOK {
			t.Fatalf("%s %s: status %d", req.Method, req.URL, w.Code)
		}
	}
	if files, _ := os.ReadDir(h.dir); out.Len() != 0 || len(files) != 0 {
		t.Fatalf("noise reported %q, saved %d files", out, len(files))
	}

	// These still reach the assistant.
	for _, req := range []*http.Request{
		httptest.NewRequest("GET", "/k3ysecretk3ysecret/meta?hub.mode=subscribe&hub.challenge=1", nil),
		httptest.NewRequest("GET", "/k3ysecretk3ysecret/x?crc_token=abc", nil),
		httptest.NewRequest("GET", "/k3ysecretk3ysecret/?challenge=abc", nil),
		httptest.NewRequest("GET", "/k3ysecretk3ysecret/", strings.NewReader("ping")),
		httptest.NewRequest("POST", "/k3ysecretk3ysecret/", nil),
		httptest.NewRequest("DELETE", "/k3ysecretk3ysecret/thing", nil),
	} {
		out.Reset()
		h.ServeHTTP(httptest.NewRecorder(), req)
		if !strings.Contains(out.String(), `"t":"webhook"`) {
			t.Errorf("%s %s was not reported", req.Method, req.URL)
		}
	}
}

// Each webhook has its own key; requests are reported under its name, and a deleted webhook's
// key stops working with the next request.
func TestPerWebhookKeys(t *testing.T) {
	h, out := newTestHandler(t)
	writeHooks(t, h.hooks.path,
		hook{Name: "github", Key: "k3ysecretk3ysecret"},
		hook{Name: "stripe", Key: "str1pesecretstr1pe"},
		hook{Name: "short", Key: "tooshort"},
		hook{Name: "empty"})
	post := func(path string) (int, string) {
		out.Reset()
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("POST", path, strings.NewReader("{}")))
		var ev struct{ Webhook, Path string }
		_ = json.Unmarshal(out.Bytes(), &ev)
		return w.Code, ev.Webhook + " " + ev.Path
	}
	if code, got := post("/str1pesecretstr1pe/charge"); code != http.StatusOK || got != "stripe /charge" {
		t.Fatalf("stripe: %d %q", code, got)
	}
	if code, got := post("/k3ysecretk3ysecret"); code != http.StatusOK || got != "github /" {
		t.Fatalf("github: %d %q", code, got)
	}
	for _, p := range []string{"/tooshort/x", "//x", "/x"} {
		if code, _ := post(p); code != http.StatusNotFound || out.Len() != 0 {
			t.Fatalf("%s: %d", p, code)
		}
	}

	writeHooks(t, h.hooks.path, hook{Name: "github", Key: "k3ysecretk3ysecret"})
	if code, _ := post("/str1pesecretstr1pe/charge"); code != http.StatusNotFound || out.Len() != 0 {
		t.Fatalf("deleted webhook still works: %d", code)
	}
	if err := os.Remove(h.hooks.path); err != nil {
		t.Fatal(err)
	}
	if code, _ := post("/k3ysecretk3ysecret/"); code != http.StatusNotFound {
		t.Fatalf("no registry: %d", code)
	}
}

// The single key of old installs keeps working as "default"; new installs start with none; an
// existing registry is never touched.
func TestMigrateRegistry(t *testing.T) {
	dir := t.TempDir()
	old := filepath.Join(dir, "old.json")
	since := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	if err := migrateRegistry(old, "legacylegacylegacy", since); err != nil {
		t.Fatal(err)
	}
	r := &registry{path: old}
	if h, ok := r.lookup("legacylegacylegacy"); !ok || h.Name != "default" || h.Created != "2026-11-01T10:00:00Z" {
		t.Fatalf("legacy webhook: %+v %v", h, ok)
	}
	if fi, _ := os.Stat(old); fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode())
	}

	fresh := filepath.Join(dir, "fresh.json")
	if err := migrateRegistry(fresh, "legacylegacylegacy", time.Time{}); err != nil {
		t.Fatal(err)
	}
	if f, err := readRegistry(fresh); err != nil || f.Webhooks == nil || len(f.Webhooks) != 0 {
		t.Fatalf("fresh registry %+v: %v", f, err)
	}

	writeHooks(t, old)
	if err := migrateRegistry(old, "legacylegacylegacy", since); err != nil {
		t.Fatal(err)
	}
	if f, _ := readRegistry(old); len(f.Webhooks) != 0 {
		t.Fatalf("migration rewrote an existing registry: %+v", f)
	}
}
