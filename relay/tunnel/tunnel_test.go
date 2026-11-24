package tunnel

import "testing"

func TestID(t *testing.T) {
	a, b := NewSecret(), NewSecret()
	if a == b || len(a) < MinSecretLength {
		t.Fatalf("secrets %q %q", a, b)
	}
	if ID(a) != ID(a) || ID(a) == ID(b) {
		t.Fatal("ID must be stable per secret and differ between secrets")
	}
	if !ValidID(ID(a)) || len(ID(a)) != IDLength {
		t.Fatalf("bad id %q", ID(a))
	}
	for _, s := range []string{"", "short", ID(a) + "a", "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxy1"} {
		if ValidID(s) {
			t.Errorf("%q should not be valid", s)
		}
	}
}
