package auth

import (
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"strings"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/store"
)

const (
	Iterations = 600_000
	SaltLength = 16
	KeyLength  = 32
)

func NewAdmin(username, password string) (store.Admin, error) {
	username = strings.TrimSpace(username)
	if len(username) < 4 || len(username) > 64 {
		return store.Admin{}, errors.New("login must contain 4 to 64 characters")
	}
	if len(password) < 12 || len(password) > 256 {
		return store.Admin{}, errors.New("password must contain 12 to 256 characters")
	}
	salt := make([]byte, SaltLength)
	if _, err := rand.Read(salt); err != nil {
		return store.Admin{}, err
	}
	key, err := pbkdf2.Key(sha256.New, password, salt, Iterations, KeyLength)
	if err != nil {
		return store.Admin{}, err
	}
	return store.Admin{
		Username:     username,
		PasswordSalt: base64.RawStdEncoding.EncodeToString(salt),
		PasswordHash: base64.RawStdEncoding.EncodeToString(key),
		Iterations:   Iterations,
	}, nil
}

func Verify(admin store.Admin, username, password string) bool {
	if subtle.ConstantTimeCompare([]byte(admin.Username), []byte(strings.TrimSpace(username))) != 1 {
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(admin.PasswordSalt)
	if err != nil {
		return false
	}
	want, err := base64.RawStdEncoding.DecodeString(admin.PasswordHash)
	if err != nil {
		return false
	}
	iterations := admin.Iterations
	if iterations <= 0 {
		iterations = Iterations
	}
	got, err := pbkdf2.Key(sha256.New, password, salt, iterations, len(want))
	if err != nil {
		return false
	}
	return subtle.ConstantTimeCompare(got, want) == 1
}
