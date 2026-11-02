package gateway

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRequestRestartChangesPrivateGeneration(t *testing.T) {
	directory := t.TempDir()
	marker := filepath.Join(directory, "ims-profile-generation")
	if err := RequestRestart(directory); err != nil {
		t.Fatal(err)
	}
	first, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if err := RequestRestart(directory); err != nil {
		t.Fatal(err)
	}
	second, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if string(first) == string(second) || len(second) != 33 {
		t.Fatalf("IMS profile generation did not change")
	}
	info, err := os.Stat(marker)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("IMS profile generation is not private: info=%v err=%v", info, err)
	}
}
