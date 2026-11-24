package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"sync"
	"time"
)

// minKeyLength keeps a short or empty key in the registry from opening the URL to guesses.
const minKeyLength = 16

// hook is one registered webhook. The app owns the registry file (it adds and deletes entries
// when the assistant asks); the helper only reads names and keys, and writes the file once, when
// it is missing (see [migrateRegistry]).
type hook struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Key         string `json:"key"`
	Created     string `json:"created,omitempty"`
}

type registryFile struct {
	Webhooks []hook `json:"webhooks"`
}

// registry maps the first path segment of a request to a registered webhook. It rereads the
// file whenever it changes, so a webhook the app deletes stops working with the next request.
type registry struct {
	path string

	mu    sync.Mutex
	mod   time.Time
	size  int64
	hooks []hook
}

// lookup returns the webhook whose key is key, if any.
func (r *registry) lookup(key string) (hook, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.reload()
	for _, h := range r.hooks {
		if len(h.Key) >= minKeyLength && subtle.ConstantTimeCompare([]byte(h.Key), []byte(key)) == 1 {
			return h, true
		}
	}
	return hook{}, false
}

// reload rereads the file if it changed. A missing file means no webhooks; an unreadable one
// keeps the last good list (the app writes it atomically, so that is only a broken edit).
func (r *registry) reload() {
	fi, err := os.Stat(r.path)
	if errors.Is(err, os.ErrNotExist) {
		r.hooks, r.mod, r.size = nil, time.Time{}, 0
		return
	}
	if err != nil || fi.ModTime().Equal(r.mod) && fi.Size() == r.size {
		return
	}
	f, err := readRegistry(r.path)
	if err != nil {
		log.Printf("webhooks registry: %v", err)
		return
	}
	r.hooks, r.mod, r.size = f.Webhooks, fi.ModTime(), fi.Size()
}

func readRegistry(path string) (registryFile, error) {
	var f registryFile
	b, err := os.ReadFile(path)
	if err != nil {
		return f, err
	}
	if err := json.Unmarshal(b, &f); err != nil {
		return f, fmt.Errorf("%s: %w", path, err)
	}
	return f, nil
}

// migrateRegistry creates the registry the first time this helper runs with one. Before
// per-webhook keys there was a single key derived from the tunnel secret: if that secret already
// existed (legacySince is its age), the old URL keeps working as the webhook "default". A fresh
// install starts with none. Once the file exists it is the app's alone.
func migrateRegistry(path, legacyKey string, legacySince time.Time) error {
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		return err
	}
	f := registryFile{Webhooks: []hook{}}
	if !legacySince.IsZero() {
		f.Webhooks = append(f.Webhooks, hook{
			Name:        "default",
			Description: "The shared address from before each webhook had its own key; senders set up with it keep working.",
			Key:         legacyKey,
			Created:     legacySince.UTC().Format(time.RFC3339),
		})
	}
	b, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
