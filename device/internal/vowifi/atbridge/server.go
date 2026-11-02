package atbridge

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"

	"sim-deck-device/internal/at"
)

const maxCommandBytes = 4096

// Commander is the existing serialized modem command path.
type Commander interface {
	Send(context.Context, string) (at.Response, error)
}

// Server exposes a local serial-style AT endpoint to a separate IMS process.
// The socket must be shared only with a trusted companion process.
type Server struct {
	listener net.Listener
	path     string
	close    sync.Once
	done     chan struct{}
	mu       sync.Mutex
	clients  map[net.Conn]struct{}
}

// Start opens a private Unix socket and forwards complete AT commands through
// the device's existing serialized client.
func Start(ctx context.Context, path string, commander Commander, timeout time.Duration) (*Server, error) {
	if path == "" || commander == nil || timeout <= 0 {
		return nil, errors.New("AT bridge requires a socket path, commander, and positive timeout")
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("AT bridge path is not a socket: %s", path)
		}
		connection, dialError := net.DialTimeout("unix", path, 200*time.Millisecond)
		if dialError == nil {
			_ = connection.Close()
			return nil, fmt.Errorf("AT bridge socket is already active: %s", path)
		}
		if !errors.Is(dialError, syscall.ECONNREFUSED) {
			return nil, fmt.Errorf("inspect existing AT bridge socket: %w", dialError)
		}
		if err := os.Remove(path); err != nil {
			return nil, fmt.Errorf("remove stale AT bridge socket: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("inspect AT bridge socket: %w", err)
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("listen for IMS AT bridge: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = listener.Close()
		_ = os.Remove(path)
		return nil, fmt.Errorf("restrict IMS AT bridge socket: %w", err)
	}
	server := &Server{listener: listener, path: path, done: make(chan struct{}), clients: make(map[net.Conn]struct{})}
	go func() {
		select {
		case <-ctx.Done():
			_ = server.Close()
		case <-server.done:
		}
	}()
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			server.mu.Lock()
			select {
			case <-server.done:
				server.mu.Unlock()
				_ = connection.Close()
				return
			default:
			}
			server.clients[connection] = struct{}{}
			server.mu.Unlock()
			go func() {
				defer func() {
					server.mu.Lock()
					delete(server.clients, connection)
					server.mu.Unlock()
					_ = connection.Close()
				}()
				serveConnection(ctx, server.done, connection, commander, timeout)
			}()
		}
	}()
	return server, nil
}

// Close stops accepting requests and removes the private socket.
func (server *Server) Close() error {
	var closeError error
	server.close.Do(func() {
		close(server.done)
		closeError = server.listener.Close()
		server.mu.Lock()
		for connection := range server.clients {
			_ = connection.Close()
		}
		server.mu.Unlock()
		_ = os.Remove(server.path)
	})
	return closeError
}

func serveConnection(ctx context.Context, done <-chan struct{}, connection net.Conn, commander Commander, timeout time.Duration) {
	reader := bufio.NewReaderSize(connection, maxCommandBytes+2)
	for {
		select {
		case <-ctx.Done():
			return
		case <-done:
			return
		default:
		}
		line, err := reader.ReadSlice('\n')
		if err != nil {
			return
		}
		command := strings.TrimSpace(string(line))
		if len(command) > maxCommandBytes || !strings.HasPrefix(command, "AT") {
			if _, err := io.WriteString(connection, "\r\nERROR\r\n"); err != nil {
				return
			}
			continue
		}
		commandContext, cancel := context.WithTimeout(ctx, timeout)
		response, err := commander.Send(commandContext, command)
		cancel()
		if err != nil {
			if _, err := io.WriteString(connection, "\r\nERROR\r\n"); err != nil {
				return
			}
			continue
		}
		var output strings.Builder
		for _, line := range response.Lines {
			output.WriteString("\r\n")
			output.WriteString(line)
			output.WriteString("\r\n")
		}
		output.WriteString("\r\n")
		output.WriteString(response.Terminal)
		output.WriteString("\r\n")
		if _, err := io.Copy(connection, strings.NewReader(output.String())); err != nil {
			return
		}
	}
}
