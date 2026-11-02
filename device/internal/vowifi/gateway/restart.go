package gateway

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
)

// RequestRestart atomically signals the companion to rebuild the carrier IMS
// line after an eSIM profile switch without exposing the ICCID in the marker.
func RequestRestart(stateDirectory string) error {
	var generation [16]byte
	if _, err := rand.Read(generation[:]); err != nil {
		return fmt.Errorf("generate IMS profile generation: %w", err)
	}
	file, err := os.CreateTemp(stateDirectory, ".ims-profile-generation-*")
	if err != nil {
		return fmt.Errorf("create IMS profile generation: %w", err)
	}
	defer os.Remove(file.Name())
	if _, err := file.WriteString(hex.EncodeToString(generation[:]) + "\n"); err != nil {
		_ = file.Close()
		return fmt.Errorf("write IMS profile generation: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close IMS profile generation: %w", err)
	}
	if err := os.Rename(file.Name(), filepath.Join(stateDirectory, "ims-profile-generation")); err != nil {
		return fmt.Errorf("publish IMS profile generation: %w", err)
	}
	return nil
}
