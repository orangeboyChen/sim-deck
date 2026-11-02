package command

import (
	"bytes"
	"crypto/ecdh"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"sim-deck-device/internal/call"
)

// TestESIMResultWireFixtures keeps the iOS regression inputs tied to the Go
// serializer and encryption code. All keys and identities are synthetic.
// Regenerate with UPDATE_ESIM_WIRE_FIXTURES=1 go test ./internal/command -run TestESIMResultWireFixtures.
func TestESIMResultWireFixtures(t *testing.T) {
	deviceKey, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{1}, 32))
	if err != nil {
		t.Fatal(err)
	}
	senderBytes := bytes.Repeat([]byte{2}, 32)
	senderKey, err := ecdh.X25519().NewPrivateKey(senderBytes)
	if err != nil {
		t.Fatal(err)
	}
	secret, err := deviceKey.ECDH(senderKey.PublicKey())
	if err != nil {
		t.Fatal(err)
	}
	envelope := Envelope{
		ID:         "01900000-0000-7000-8000-000000000404",
		DeviceUUID: "01900000-0000-7000-8000-000000000401",
	}
	type vector struct {
		Name       string `json:"name"`
		Plaintext  string `json:"plaintext"`
		Nonce      []byte `json:"nonce"`
		Ciphertext []byte `json:"ciphertext"`
	}
	fixture := struct {
		DeviceID         string   `json:"deviceID"`
		CommandID        string   `json:"commandID"`
		DevicePublicKey  []byte   `json:"devicePublicKey"`
		SenderPrivateKey []byte   `json:"senderPrivateKey"`
		Results          []vector `json:"results"`
	}{DeviceID: envelope.DeviceUUID, CommandID: envelope.ID, DevicePublicKey: deviceKey.PublicKey().Bytes(), SenderPrivateKey: senderBytes}
	empty := []ESIMProfile{}
	var nullProfiles []ESIMProfile
	cases := []struct {
		name      string
		profiles  *[]ESIMProfile
		errorCode string
	}{
		{"empty", &empty, ""},
		{"null", &nullProfiles, ""},
		{"omitted", nil, ""},
	}
	for _, metadata := range []struct{ name, nickname, provider string }{
		{"without_metadata", "", ""},
		{"nickname_only", "Travel", ""},
		{"provider_only", "", "Example Mobile"},
		{"full_metadata", "Travel", "Example Mobile"},
	} {
		profiles := []ESIMProfile{{ProfileID: "89000000000000000001", ICCID: "89000000000000000001", Enabled: false, Nickname: metadata.nickname, Provider: metadata.provider}}
		cases = append(cases, struct {
			name      string
			profiles  *[]ESIMProfile
			errorCode string
		}{metadata.name, &profiles, ""})
	}
	for _, code := range []string{"esim_unavailable", "wrong_sim_slot", "modem_rejected"} {
		cases = append(cases, struct {
			name      string
			profiles  *[]ESIMProfile
			errorCode string
		}{code, nil, code})
	}
	for _, testCase := range cases {
		result := Result{Version: 1, Success: testCase.errorCode == "", ErrorCode: testCase.errorCode, CallState: call.StateIdle, ESIMProfiles: testCase.profiles}
		plaintext, err := json.Marshal(result)
		if err != nil {
			t.Fatal(err)
		}
		encrypted, err := sealResult(bytes.NewReader(bytes.Repeat([]byte{9}, nonceBytes)), secret, envelope, result)
		if err != nil {
			t.Fatal(err)
		}
		fixture.Results = append(fixture.Results, vector{testCase.name, string(plaintext), encrypted.Nonce, encrypted.Ciphertext})
	}
	encoded, err := json.MarshalIndent(fixture, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	encoded = append(encoded, '\n')
	path := filepath.Join("..", "..", "..", "ios", "SimDeckTests", "Fixtures", "esim-command-results.json")
	if os.Getenv("UPDATE_ESIM_WIRE_FIXTURES") == "1" {
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, encoded, 0644); err != nil {
			t.Fatal(err)
		}
	}
	expected, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(encoded, expected) {
		t.Fatal("eSIM wire format changed; regenerate the fixture and run the iOS transport tests")
	}
}
