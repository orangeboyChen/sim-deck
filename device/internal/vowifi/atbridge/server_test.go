package atbridge

import (
	"bufio"
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"sim-deck-device/internal/at"
)

type fakeCommander struct {
	mu       sync.Mutex
	commands []string
	response at.Response
	err      error
}

func (fake *fakeCommander) Send(_ context.Context, command string) (at.Response, error) {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	fake.commands = append(fake.commands, command)
	return fake.response, fake.err
}

func socketPath(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "sd-at-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	return filepath.Join(directory, "at.sock")
}

func TestBridgeSerializesResponsesThroughExistingCommander(t *testing.T) {
	path := socketPath(t)
	commander := &fakeCommander{response: at.Response{Lines: []string{`+CSIM: 4,"9000"`}, Terminal: "OK"}}
	server, err := Start(context.Background(), path, commander, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("socket permission = %v, error = %v", info, err)
	}
	connection, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.SetDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := connection.Write([]byte("AT+CSIM=4,\"9000\"\r\n")); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(connection)
	for _, want := range []string{"\r\n", "+CSIM: 4,\"9000\"\r\n", "\r\n", "OK\r\n"} {
		line, err := reader.ReadString('\n')
		if err != nil || line != want {
			t.Fatalf("response line = %q, error = %v, want %q", line, err, want)
		}
	}
	commander.mu.Lock()
	defer commander.mu.Unlock()
	if len(commander.commands) != 1 || commander.commands[0] != `AT+CSIM=4,"9000"` {
		t.Fatalf("forwarded commands = %q", commander.commands)
	}
}

func TestBridgeRejectsNonATInputAndReportsModemErrors(t *testing.T) {
	path := socketPath(t)
	commander := &fakeCommander{err: errors.New("serial failed")}
	server, err := Start(context.Background(), path, commander, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	connection, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(time.Second))
	reader := bufio.NewReader(connection)
	for _, command := range []string{"BAD\r\n", "AT+CIMI\r\n"} {
		if _, err := connection.Write([]byte(command)); err != nil {
			t.Fatal(err)
		}
		for _, want := range []string{"\r\n", "ERROR\r\n"} {
			line, err := reader.ReadString('\n')
			if err != nil || line != want {
				t.Fatalf("response line = %q, error = %v, want %q", line, err, want)
			}
		}
	}
	commander.mu.Lock()
	defer commander.mu.Unlock()
	if len(commander.commands) != 1 || commander.commands[0] != "AT+CIMI" {
		t.Fatalf("forwarded commands = %q", commander.commands)
	}
}

func TestBridgeClosesConnectedClientsAndRemovesSocket(t *testing.T) {
	path := socketPath(t)
	server, err := Start(context.Background(), path, &fakeCommander{}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	connection, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket should be removed: %v", err)
	}
	_ = connection.SetReadDeadline(time.Now().Add(time.Second))
	buffer := make([]byte, 1)
	if _, err := connection.Read(buffer); err == nil {
		t.Fatal("client remained connected after server close")
	}
}

func TestBridgeReplacesStaleSocketButNotActiveListener(t *testing.T) {
	path := socketPath(t)
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Start(context.Background(), path, &fakeCommander{}, time.Second); err == nil {
		t.Fatal("bridge replaced an active listener")
	}
	listener.(*net.UnixListener).SetUnlinkOnClose(false)
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	server, err := Start(context.Background(), path, &fakeCommander{}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
}
