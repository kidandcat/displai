// Package tunnel carries raw TCP connections from the relay to a Minerva desktop, so third
// parties can reach the desktop (webhooks) while it stays behind NAT, and without the relay
// seeing what they send: TLS is terminated on the desktop, the relay only moves ciphertext.
//
// Protocol (all WebSockets to the relay, authenticated with "Authorization: Bearer <secret>"):
//
//	GET /tunnel              the control connection the desktop keeps open. The relay sends
//	                         {"t":"open","c":"<token>","ip":"<client ip>"} for every incoming
//	                         connection to <id>.<domain>.
//	GET /tunnel/accept?c=…   the desktop answers each "open" with one of these; its binary
//	                         messages are the incoming connection's bytes, both ways.
//
// The desktop's id (its webhook host name is <id>.<domain>) is derived from the secret with
// [ID], so the relay needs no registry and nobody who only knows the URL can take it over.
package tunnel

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// MinSecretLength is the shortest secret the relay accepts.
const MinSecretLength = 32

// IDLength is the length of an [ID]: 16 bytes of SHA-256 in base32.
const IDLength = 26

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

// ID is the desktop's public name for its secret: 26 lowercase base32 characters.
func ID(secret string) string {
	sum := sha256.Sum256([]byte("minerva tunnel id v1\x00" + secret))
	return strings.ToLower(b32.EncodeToString(sum[:16]))
}

// PathKey is the secret first path segment of the desktop's webhook URL. The [ID] cannot stay
// private: it is the host name of a public certificate, so it shows up in Certificate
// Transparency logs and scanners probe it within seconds. Only requests under this key count.
func PathKey(secret string) string {
	sum := sha256.Sum256([]byte("minerva webhook path v1\x00" + secret))
	return strings.ToLower(b32.EncodeToString(sum[:15]))
}

// ValidID reports whether s looks like an [ID].
func ValidID(s string) bool {
	if len(s) != IDLength {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '2' && c <= '7') {
			return false
		}
	}
	return true
}

// NewSecret returns a fresh random secret.
func NewSecret() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// Open is the relay's notice of an incoming connection.
type Open struct {
	T  string `json:"t"`
	C  string `json:"c"`
	IP string `json:"ip,omitempty"`
}

// Listener is the desktop's end: a net.Listener whose connections arrive through the relay.
// It keeps the control connection up (reconnecting with backoff) until closed.
type Listener struct {
	relay  string // ws(s)://host[:port]
	secret string
	conns  chan net.Conn
	ctx    context.Context
	cancel context.CancelFunc

	mu     sync.Mutex
	online bool

	// OnState, if set, is called when the control connection goes up or down (err is why).
	OnState func(online bool, err error)
}

// Listen starts the desktop's end of the tunnel through relay (e.g. wss://minerva.kidandcat.com).
func Listen(relay, secret string) *Listener {
	ctx, cancel := context.WithCancel(context.Background())
	l := &Listener{
		relay:  strings.TrimRight(relay, "/"),
		secret: secret,
		conns:  make(chan net.Conn),
		ctx:    ctx,
		cancel: cancel,
	}
	return l
}

// Start runs the control loop; call it after setting OnState.
func (l *Listener) Start() *Listener {
	go l.run()
	return l
}

func (l *Listener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.ctx.Done():
		return nil, net.ErrClosed
	}
}

func (l *Listener) Close() error {
	l.cancel()
	return nil
}

func (l *Listener) Addr() net.Addr { return tunnelAddr(ID(l.secret)) }

// Online reports whether the control connection is up.
func (l *Listener) Online() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.online
}

func (l *Listener) setOnline(on bool, err error) {
	l.mu.Lock()
	changed := l.online != on
	l.online = on
	l.mu.Unlock()
	if changed && l.OnState != nil {
		l.OnState(on, err)
	}
}

func (l *Listener) header() http.Header {
	return http.Header{"Authorization": {"Bearer " + l.secret}}
}

func (l *Listener) run() {
	backoff := time.Second
	for l.ctx.Err() == nil {
		start := time.Now()
		err := l.control()
		l.setOnline(false, err)
		if l.ctx.Err() != nil {
			return
		}
		if time.Since(start) > time.Minute {
			backoff = time.Second
		}
		log.Printf("tunnel: %v (retrying in %s)", err, backoff)
		select {
		case <-time.After(backoff):
		case <-l.ctx.Done():
			return
		}
		backoff = min(backoff*2, time.Minute)
	}
}

func (l *Listener) control() error {
	ctx, cancel := context.WithTimeout(l.ctx, 15*time.Second)
	c, _, err := websocket.Dial(ctx, l.relay+"/tunnel", &websocket.DialOptions{HTTPHeader: l.header()})
	cancel()
	if err != nil {
		return err
	}
	defer c.CloseNow()
	l.setOnline(true, nil)
	ctx, cancel = context.WithCancel(l.ctx)
	defer cancel()
	go keepAlive(ctx, c)
	for {
		typ, data, err := c.Read(ctx)
		if err != nil {
			return err
		}
		var o Open
		if typ != websocket.MessageText || json.Unmarshal(data, &o) != nil || o.T != "open" || o.C == "" {
			continue
		}
		go l.accept(o)
	}
}

func (l *Listener) accept(o Open) {
	ctx, cancel := context.WithTimeout(l.ctx, 15*time.Second)
	c, _, err := websocket.Dial(ctx, l.relay+"/tunnel/accept?c="+o.C, &websocket.DialOptions{HTTPHeader: l.header()})
	cancel()
	if err != nil {
		return
	}
	c.SetReadLimit(-1)
	// The relay closes the WebSocket when the far end is gone; the net.Conn's context only has to
	// outlive it.
	nc := &conn{Conn: websocket.NetConn(l.ctx, c, websocket.MessageBinary), remote: tunnelAddr(o.IP)}
	select {
	case l.conns <- nc:
	case <-l.ctx.Done():
		nc.Close()
	}
}

// conn reports the original client's address instead of the relay's.
type conn struct {
	net.Conn
	remote net.Addr
}

func (c *conn) RemoteAddr() net.Addr { return c.remote }

type tunnelAddr string

func (tunnelAddr) Network() string  { return "tunnel" }
func (a tunnelAddr) String() string { return string(a) }

// KeepAlive pings c until ctx ends, and closes it when a ping goes unanswered.
func keepAlive(ctx context.Context, c *websocket.Conn) {
	t := time.NewTicker(25 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			pctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := c.Ping(pctx)
			cancel()
			if err != nil && !errors.Is(err, context.Canceled) {
				c.Close(websocket.StatusGoingAway, "ping timeout")
				return
			}
		}
	}
}
