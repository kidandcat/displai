package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

const testKey = "0123456789abcdef0123456789abcdef-test"

func dial(t *testing.T, url, role, key string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, strings.Replace(url, "http", "ws", 1)+"/ws?role="+role,
		&websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer " + key}}})
	if err != nil {
		t.Fatalf("dial %s: %v", role, err)
	}
	return c
}

func read(t *testing.T, c *websocket.Conn) (websocket.MessageType, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	typ, data, err := c.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return typ, string(data)
}

func write(t *testing.T, c *websocket.Conn, typ websocket.MessageType, s string) {
	t.Helper()
	if err := c.Write(context.Background(), typ, []byte(s)); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func TestPairsAndForwards(t *testing.T) {
	srv := httptest.NewServer(newRelay("minerva.test").routes())
	defer srv.Close()

	host := dial(t, srv.URL, "host", testKey)
	if _, m := read(t, host); m != `{"t":"peer","up":false}` {
		t.Fatalf("host alone: %s", m)
	}
	remote := dial(t, srv.URL, "remote", testKey)
	if _, m := read(t, host); m != `{"t":"peer","up":true}` {
		t.Fatalf("host sees remote: %s", m)
	}
	if _, m := read(t, remote); m != `{"t":"peer","up":true}` {
		t.Fatalf("remote sees host: %s", m)
	}

	write(t, remote, websocket.MessageBinary, "\x01pcm")
	if typ, m := read(t, host); typ != websocket.MessageBinary || m != "\x01pcm" {
		t.Fatalf("binary to host: %v %q", typ, m)
	}
	write(t, host, websocket.MessageText, `{"t":"state"}`)
	if _, m := read(t, remote); m != `{"t":"state"}` {
		t.Fatalf("text to remote: %s", m)
	}

	// Another key is another room: nothing crosses.
	stranger := dial(t, srv.URL, "remote", testKey+"-other")
	if _, m := read(t, stranger); m != `{"t":"peer","up":false}` {
		t.Fatalf("stranger: %s", m)
	}

	// A newer remote replaces the old one.
	remote2 := dial(t, srv.URL, "remote", testKey)
	if _, m := read(t, remote2); m != `{"t":"peer","up":true}` {
		t.Fatalf("remote2: %s", m)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, _, err := remote.Read(ctx); websocket.CloseStatus(err) != 4000 {
		t.Fatalf("old remote should be replaced, got %v", err)
	}
	_, _ = read(t, host) // peer up for remote2

	remote2.Close(websocket.StatusNormalClosure, "")
	if _, m := read(t, host); m != `{"t":"peer","up":false}` {
		t.Fatalf("host sees remote leave: %s", m)
	}
}

func TestRejectsShortKey(t *testing.T) {
	srv := httptest.NewServer(newRelay("minerva.test").routes())
	defer srv.Close()
	_, resp, err := websocket.Dial(context.Background(), strings.Replace(srv.URL, "http", "ws", 1)+"/ws?role=host",
		&websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer short"}}})
	if err == nil || resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("want 401, got %v %v", resp, err)
	}
}
