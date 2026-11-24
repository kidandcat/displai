// Command minerva-relay pairs a Minerva desktop (the host, where all the processing runs) with
// its phone remote. Both sides dial out to the relay, so the desktop can stay behind NAT.
//
// Each side connects to /ws?role=host or /ws?role=remote with the same room token in
// "Authorization: Bearer <token>". The room is the SHA-256 of the token. Frames are forwarded
// verbatim to the other side; the relay itself only sends {"t":"peer","up":true|false} when the
// other side joins or leaves.
//
// The relay is untrusted by design: the clients derive the room token from the pairing key they
// share through a QR code, and encrypt everything end to end with keys the relay cannot derive
// (app/lib/remote/secure_channel.dart). Run with -tap to log what each forwarded frame looks like
// from here.
//
// With -tls-addr it also carries the desktops' webhooks: TLS connections to <id>.<tunnel domain>
// are passed through, still encrypted, to the desktop that owns the id (passthrough.go).
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	maxRooms     = 200
	readLimit    = 16 << 20 // a display snapshot (PNG, base64) can be a few MB
	writeTimeout = 10 * time.Second
	pingInterval = 25 * time.Second
	minKeyLength = 32
)

type peer struct {
	conn *websocket.Conn
	done chan struct{}
}

type room struct {
	host, remote *peer
}

type relay struct {
	mu    sync.Mutex
	rooms map[string]*room
	tap   bool // log what every forwarded frame looks like to the relay

	pass *passthrough // webhooks for the desktops (passthrough.go)
}

func newRelay(tunnelDomain string) *relay {
	return &relay{rooms: map[string]*room{}, pass: newPassthrough(tunnelDomain)}
}

func (r *relay) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("GET /ws", r.serveWS)
	r.pass.routes(mux)
	return mux
}

func (r *relay) serveWS(w http.ResponseWriter, req *http.Request) {
	role := req.URL.Query().Get("role")
	if role != "host" && role != "remote" {
		http.Error(w, "role must be host or remote", http.StatusBadRequest)
		return
	}
	key := strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer ")
	if len(key) < minKeyLength {
		http.Error(w, "missing or short pairing key", http.StatusUnauthorized)
		return
	}
	sum := sha256.Sum256([]byte(key))
	id := hex.EncodeToString(sum[:])

	conn, err := websocket.Accept(w, req, nil)
	if err != nil {
		return
	}
	conn.SetReadLimit(readLimit)
	p := &peer{conn: conn, done: make(chan struct{})}
	other, old, ok := r.join(id, role, p)
	if !ok {
		conn.Close(websocket.StatusTryAgainLater, "relay full")
		return
	}
	if old != nil {
		// Close waits for the close handshake; do not hold up the new connection.
		go old.conn.Close(4000, "replaced by a newer connection")
	}
	log.Printf("room %s: %s joined", id[:8], role)
	if other != nil {
		// The newcomer hears first, so the handshake the other side starts on its notice always
		// arrives after the newcomer's own notice.
		notifyPeer(p, true)
		notifyPeer(other, true)
	} else {
		notifyPeer(p, false)
	}

	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	go keepAlive(ctx, conn)
	for {
		typ, data, err := conn.Read(ctx)
		if err != nil {
			break
		}
		if r.tap {
			tapFrame(id, role, typ, data)
		}
		if dst := r.other(id, role, p); dst != nil {
			wctx, wcancel := context.WithTimeout(ctx, writeTimeout)
			if err := dst.conn.Write(wctx, typ, data); err != nil && !errors.Is(err, context.Canceled) {
				dst.conn.Close(websocket.StatusPolicyViolation, "too slow")
			}
			wcancel()
		}
	}
	close(p.done)
	if other := r.leave(id, role, p); other != nil {
		notifyPeer(other, false)
	}
	conn.Close(websocket.StatusNormalClosure, "")
	log.Printf("room %s: %s left", id[:8], role)
}

// join places p in its room, replacing an older connection with the same role.
func (r *relay) join(id, role string, p *peer) (other, old *peer, ok bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	rm := r.rooms[id]
	if rm == nil {
		if len(r.rooms) >= maxRooms {
			return nil, nil, false
		}
		rm = &room{}
		r.rooms[id] = rm
	}
	if role == "host" {
		old, rm.host, other = rm.host, p, rm.remote
	} else {
		old, rm.remote, other = rm.remote, p, rm.host
	}
	return other, old, true
}

func (r *relay) other(id, role string, p *peer) *peer {
	r.mu.Lock()
	defer r.mu.Unlock()
	rm := r.rooms[id]
	if rm == nil {
		return nil
	}
	if role == "host" && rm.host == p {
		return rm.remote
	}
	if role == "remote" && rm.remote == p {
		return rm.host
	}
	return nil
}

// leave removes p (unless a newer connection already replaced it) and returns the other side.
func (r *relay) leave(id, role string, p *peer) *peer {
	r.mu.Lock()
	defer r.mu.Unlock()
	rm := r.rooms[id]
	if rm == nil {
		return nil
	}
	var other *peer
	switch {
	case role == "host" && rm.host == p:
		rm.host, other = nil, rm.remote
	case role == "remote" && rm.remote == p:
		rm.remote, other = nil, rm.host
	default:
		return nil
	}
	if rm.host == nil && rm.remote == nil {
		delete(r.rooms, id)
	}
	return other
}

// tapFrame logs a forwarded frame as the relay sees it: the clients encrypt everything but the
// handshake end to end, so binary frames should look like noise and text frames carry only
// ephemeral public keys.
func tapFrame(id, role string, typ websocket.MessageType, data []byte) {
	if typ == websocket.MessageText {
		s := string(data)
		if len(s) > 160 {
			s = s[:160] + "…"
		}
		log.Printf("tap %s %s text %6d B  %s", id[:8], role, len(data), s)
		return
	}
	n := min(len(data), 32)
	log.Printf("tap %s %s bin  %6d B  %x…", id[:8], role, len(data), data[:n])
}

func notifyPeer(p *peer, up bool) {
	msg := `{"t":"peer","up":false}`
	if up {
		msg = `{"t":"peer","up":true}`
	}
	ctx, cancel := context.WithTimeout(context.Background(), writeTimeout)
	defer cancel()
	_ = p.conn.Write(ctx, websocket.MessageText, []byte(msg))
}

func keepAlive(ctx context.Context, c *websocket.Conn) {
	t := time.NewTicker(pingInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			pctx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := c.Ping(pctx)
			cancel()
			if err != nil {
				c.Close(websocket.StatusGoingAway, "ping timeout")
				return
			}
		}
	}
}

func main() {
	addr := flag.String("addr", "127.0.0.1:8094", "listen address")
	tap := flag.Bool("tap", false, "log every forwarded frame as the relay sees it (to check the encryption)")
	tlsAddr := flag.String("tls-addr", "", "TLS passthrough listen address for the desktops' webhooks, e.g. :443 (empty: off)")
	tunnelDomain := flag.String("tunnel-domain", "minerva.kidandcat.com", "webhook hosts are <id>.<this domain>")
	fallback := flag.String("tls-fallback", "", "where -tls-addr sends every other TLS name, e.g. 127.0.0.1:8443 (empty: close them)")
	proxyProto := flag.Bool("tls-fallback-proxy-protocol", false, "send a PROXY v2 header to -tls-fallback")
	flag.Parse()
	r := newRelay(*tunnelDomain)
	r.tap = *tap
	r.pass.fallback = *fallback
	r.pass.proxyProtocol = *proxyProto
	if *tlsAddr != "" {
		ln, err := net.Listen("tcp", *tlsAddr)
		if err != nil {
			log.Fatal(err)
		}
		log.Printf("tls passthrough for *.%s on %s", r.pass.domain, *tlsAddr)
		go func() { log.Fatal(r.pass.serve(ln)) }()
	}
	srv := &http.Server{Addr: *addr, Handler: r.routes(), ReadHeaderTimeout: 10 * time.Second}
	log.Printf("minerva-relay listening on %s", *addr)
	log.Fatal(srv.ListenAndServe())
}
