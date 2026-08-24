package auth

import "testing"

func TestNewAdminAndVerify(t *testing.T) {
	admin, err := NewAdmin("router-admin", "a reasonably long passphrase")
	if err != nil {
		t.Fatal(err)
	}
	if !Verify(admin, "router-admin", "a reasonably long passphrase") {
		t.Fatal("valid credentials rejected")
	}
	if Verify(admin, "router-admin", "wrong password") {
		t.Fatal("invalid password accepted")
	}
	if admin.PasswordHash == "a reasonably long passphrase" {
		t.Fatal("password stored in clear text")
	}
}

func TestPasswordPolicy(t *testing.T) {
	if _, err := NewAdmin("abc", "a reasonably long passphrase"); err == nil {
		t.Fatal("short login accepted")
	}
	if _, err := NewAdmin("router-admin", ""); err == nil {
		t.Fatal("empty password accepted")
	}
	if _, err := NewAdmin("router-admin", "x"); err != nil {
		t.Fatalf("non-empty short password rejected: %v", err)
	}
}
