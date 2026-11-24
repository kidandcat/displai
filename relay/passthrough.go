package main

// Webhooks for the desktops (see package tunnel): a TLS listener that reads only the SNI of each
// incoming connection and, for <id>.<tunnel domain>, pipes the raw bytes to that desktop through
// its tunnel. TLS ends on the desktop with its own certificate, so the relay never holds a key
// for those names and cannot read what they receive. Other names go to -tls-fallback (Caddy, when
// the relay owns :443) or are closed.

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/kidandcat/minerva/relay/tunnel"
)

const (
	maxTunnels       = 1000
	maxPendingPerID  = 32
	helloTimeout     = 10 * time.Second
	pickupTimeout    = 15 * time.Second
	maxConnLifetime  = 15 * time.Minute
	maxClientHelloSz = 16 << 10
)

// passthrough routes TLS connections by SNI.
type passthrough struct {
	domain        string // webhook hosts are <id>.<domain>
	fallback      string // where other names go ("" closes them)
	proxyProtocol bool   // send a PROXY v2 header to fallback

	mu      sync.Mutex
	tunnels map[string]*tunnelPeer
}

type tunnelPeer struct {
	conn    *websocket.Conn
	pending map[string]*pendingConn
}

// pendingConn is an incoming connection waiting for its desktop to pick it up.
type pendingConn struct {
	client net.Conn
	hello  []byte        // what was read to find the SNI, replayed first
	taken  chan struct{} // closed when an accept took it
}

func newPassthrough(domain string) *passthrough {
	return &passthrough{domain: strings.ToLower(strings.Trim(domain, ".")), tunnels: map[string]*tunnelPeer{}}
}

func (p *passthrough) routes(mux *http.ServeMux) {
	mux.HandleFunc("GET /tunnel", p.serveControl)
	mux.HandleFunc("GET /tunnel/accept", p.serveAccept)
}

// tunnelID authenticates a desktop: the id is derived from the secret it presents.
func tunnelID(req *http.Request) (string, bool) {
	secret := strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer ")
	if len(secret) < tunnel.MinSecretLength {
		return "", false
	}
	return tunnel.ID(secret), true
}

func (p *passthrough) serveControl(w http.ResponseWriter, req *http.Request) {
	id, ok := tunnelID(req)
	if !ok {
		http.Error(w, "missing or short secret", http.StatusUnauthorized)
		return
	}
	conn, err := websocket.Accept(w, req, nil)
	if err != nil {
		return
	}
	t := &tunnelPeer{conn: conn, pending: map[string]*pendingConn{}}
	p.mu.Lock()
	old := p.tunnels[id]
	if old == nil && len(p.tunnels) >= maxTunnels {
		p.mu.Unlock()
		conn.Close(websocket.StatusTryAgainLater, "relay full")
		return
	}
	p.tunnels[id] = t
	p.mu.Unlock()
	if old != nil {
		go old.conn.Close(4000, "replaced by a newer connection")
	}
	log.Printf("tunnel %s: up", id[:8])

	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	go keepAlive(ctx, conn)
	for {
		// The desktop sends nothing on the control connection; reading keeps pings flowing.
		if _, _, err := conn.Read(ctx); err != nil {
			break
		}
	}
	p.mu.Lock()
	if p.tunnels[id] == t {
		delete(p.tunnels, id)
	}
	p.mu.Unlock()
	conn.Close(websocket.StatusNormalClosure, "")
	log.Printf("tunnel %s: down", id[:8])
}

func (p *passthrough) serveAccept(w http.ResponseWriter, req *http.Request) {
	id, ok := tunnelID(req)
	if !ok {
		http.Error(w, "missing or short secret", http.StatusUnauthorized)
		return
	}
	token := req.URL.Query().Get("c")
	p.mu.Lock()
	var pc *pendingConn
	if t := p.tunnels[id]; t != nil {
		pc = t.pending[token]
		delete(t.pending, token)
	}
	p.mu.Unlock()
	if pc == nil {
		http.Error(w, "no such connection", http.StatusNotFound)
		return
	}
	close(pc.taken)
	defer pc.client.Close()
	conn, err := websocket.Accept(w, req, nil)
	if err != nil {
		return
	}
	conn.SetReadLimit(-1)
	ctx, cancel := context.WithTimeout(context.Background(), maxConnLifetime)
	defer cancel()
	nc := websocket.NetConn(ctx, conn, websocket.MessageBinary)
	defer nc.Close()
	if _, err := nc.Write(pc.hello); err != nil {
		return
	}
	in, out := pipe(nc, pc.client)
	log.Printf("tunnel %s: connection done (%d B in, %d B out)", id[:8], int64(len(pc.hello))+in, out)
}

// pipe copies both ways until either side is done (TLS has its own close_notify, so no
// half-close is needed), and returns the bytes client→desktop and back.
func pipe(desktop, client net.Conn) (in, out int64) {
	done := make(chan struct{})
	go func() {
		out, _ = io.Copy(client, desktop)
		client.Close()
		desktop.Close()
		close(done)
	}()
	in, _ = io.Copy(desktop, client)
	client.Close()
	desktop.Close()
	<-done
	return in, out
}

// serve accepts TLS connections on ln until it is closed.
func (p *passthrough) serve(ln net.Listener) error {
	for {
		c, err := ln.Accept()
		if err != nil {
			return err
		}
		go p.handle(c)
	}
}

func (p *passthrough) handle(c net.Conn) {
	_ = c.SetReadDeadline(time.Now().Add(helloTimeout))
	name, hello, err := peekSNI(c)
	_ = c.SetReadDeadline(time.Time{})
	if err != nil && len(hello) == 0 {
		c.Close()
		return
	}
	if id, ok := p.idFor(name); ok {
		p.toDesktop(id, c, hello)
		return
	}
	if p.fallback == "" {
		c.Close()
		return
	}
	p.toFallback(c, hello)
}

// idFor returns the desktop id when name is <id>.<domain>.
func (p *passthrough) idFor(name string) (string, bool) {
	name = strings.ToLower(strings.TrimSuffix(name, "."))
	id, ok := strings.CutSuffix(name, "."+p.domain)
	if !ok || p.domain == "" || !tunnel.ValidID(id) {
		return "", false
	}
	return id, true
}

func (p *passthrough) toDesktop(id string, c net.Conn, hello []byte) {
	token := newToken()
	pc := &pendingConn{client: c, hello: hello, taken: make(chan struct{})}
	p.mu.Lock()
	t := p.tunnels[id]
	if t == nil || len(t.pending) >= maxPendingPerID {
		p.mu.Unlock()
		c.Close()
		return
	}
	t.pending[token] = pc
	p.mu.Unlock()

	ip := ""
	if a, ok := c.RemoteAddr().(*net.TCPAddr); ok {
		ip = a.IP.String()
	}
	msg, _ := json.Marshal(tunnel.Open{T: "open", C: token, IP: ip})
	ctx, cancel := context.WithTimeout(context.Background(), writeTimeout)
	err := t.conn.Write(ctx, websocket.MessageText, msg)
	cancel()
	if err == nil {
		select {
		case <-pc.taken:
			return // serveAccept owns it now
		case <-time.After(pickupTimeout):
		}
	}
	p.mu.Lock()
	_, still := t.pending[token]
	delete(t.pending, token)
	p.mu.Unlock()
	if still {
		c.Close()
	}
}

func (p *passthrough) toFallback(c net.Conn, hello []byte) {
	defer c.Close()
	f, err := net.DialTimeout("tcp", p.fallback, 5*time.Second)
	if err != nil {
		log.Printf("tls fallback: %v", err)
		return
	}
	defer f.Close()
	if p.proxyProtocol {
		if _, err := f.Write(proxyHeader(c.RemoteAddr(), c.LocalAddr())); err != nil {
			return
		}
	}
	if _, err := f.Write(hello); err != nil {
		return
	}
	pipe(f, c)
}

func newToken() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// peekSNI reads the TLS ClientHello from c without answering it, and returns the server name
// and every byte it read (to replay to whoever terminates TLS).
func peekSNI(c net.Conn) (string, []byte, error) {
	var buf bytes.Buffer
	r := io.TeeReader(io.LimitReader(c, maxClientHelloSz), &buf)
	var name string
	errDone := errors.New("got the hello")
	err := tls.Server(readOnlyConn{r: r, c: c}, &tls.Config{
		GetConfigForClient: func(h *tls.ClientHelloInfo) (*tls.Config, error) {
			name = h.ServerName
			return nil, errDone
		},
	}).Handshake()
	if name == "" && !errors.Is(err, errDone) {
		return "", buf.Bytes(), err
	}
	return name, buf.Bytes(), nil
}

// readOnlyConn lets crypto/tls parse a ClientHello but not answer it.
type readOnlyConn struct {
	r io.Reader
	c net.Conn
}

func (c readOnlyConn) Read(b []byte) (int, error)     { return c.r.Read(b) }
func (readOnlyConn) Write([]byte) (int, error)        { return 0, io.ErrClosedPipe }
func (readOnlyConn) Close() error                     { return nil }
func (c readOnlyConn) LocalAddr() net.Addr            { return c.c.LocalAddr() }
func (c readOnlyConn) RemoteAddr() net.Addr           { return c.c.RemoteAddr() }
func (readOnlyConn) SetDeadline(time.Time) error      { return nil }
func (readOnlyConn) SetReadDeadline(time.Time) error  { return nil }
func (readOnlyConn) SetWriteDeadline(time.Time) error { return nil }

// proxyHeader is a PROXY protocol v2 header, so the fallback sees the client's address.
func proxyHeader(src, dst net.Addr) []byte {
	h := []byte("\r\n\r\n\x00\r\nQUIT\n")
	s, ok1 := src.(*net.TCPAddr)
	d, ok2 := dst.(*net.TCPAddr)
	if !ok1 || !ok2 {
		return append(h, 0x20, 0x00, 0, 0) // LOCAL: no addresses
	}
	sa, _ := netip.AddrFromSlice(s.IP)
	da, _ := netip.AddrFromSlice(d.IP)
	sa, da = sa.Unmap(), da.Unmap()
	h = append(h, 0x21) // v2, PROXY
	if sa.Is4() && da.Is4() {
		h = append(h, 0x11) // TCP over IPv4
		h = binary.BigEndian.AppendUint16(h, 12)
	} else {
		sa, da = netip.AddrFrom16(sa.As16()), netip.AddrFrom16(da.As16())
		h = append(h, 0x21) // TCP over IPv6
		h = binary.BigEndian.AppendUint16(h, 36)
	}
	h = append(h, sa.AsSlice()...)
	h = append(h, da.AsSlice()...)
	h = binary.BigEndian.AppendUint16(h, uint16(s.Port))
	h = binary.BigEndian.AppendUint16(h, uint16(d.Port))
	return h
}
