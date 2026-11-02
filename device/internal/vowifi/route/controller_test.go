package route

import (
	"bytes"
	"context"
	"errors"
	"io"
	"sync"
	"testing"
	"time"

	"sim-deck-device/internal/at"
	"sim-deck-device/internal/call"
	"sim-deck-device/internal/media"
)

type testCommander struct {
	mu       sync.Mutex
	commands []string
}

func (commander *testCommander) Send(_ context.Context, command string) (at.Response, error) {
	commander.mu.Lock()
	commander.commands = append(commander.commands, command)
	commander.mu.Unlock()
	return at.Response{Terminal: "OK"}, nil
}

type testLine struct {
	incoming   chan SIPCall
	dialed     chan string
	answer     chan SIPCall
	registered bool
	stop       chan error
}

func (line *testLine) Run(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case err := <-line.stop:
		return err
	}
}
func (line *testLine) Registered() bool              { return line.registered }
func (line *testLine) IncomingCalls() <-chan SIPCall { return line.incoming }
func (line *testLine) Close() error                  { return nil }
func (line *testLine) DialCall(ctx context.Context, number string, _ func(int)) (SIPCall, error) {
	line.dialed <- number
	select {
	case dialog := <-line.answer:
		return dialog, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

type testPCM struct{ bytes.Buffer }

func (*testPCM) Close() error { return nil }

type testCall struct {
	number string
	pcm    *testPCM
	done   chan struct{}
	once   sync.Once
	dtmf   chan rune
}

func newTestCall(number string) *testCall {
	return &testCall{number: number, pcm: &testPCM{}, done: make(chan struct{}), dtmf: make(chan rune, 1)}
}
func (dialog *testCall) Number() string        { return dialog.number }
func (dialog *testCall) Done() <-chan struct{} { return dialog.done }
func (dialog *testCall) PCM() media.DuplexPCM  { return dialog.pcm }
func (dialog *testCall) Answer() error         { return nil }
func (dialog *testCall) Hangup(context.Context) error {
	dialog.once.Do(func() { close(dialog.done) })
	return nil
}
func (dialog *testCall) SendDTMF(digit rune) error { dialog.dtmf <- digit; return nil }

func waitState(t *testing.T, events <-chan call.Snapshot, expected call.State) {
	t.Helper()
	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	for {
		select {
		case snapshot := <-events:
			if snapshot.State == expected {
				return
			}
		case <-timer.C:
			t.Fatalf("call state %s was not published", expected)
		}
	}
}

func setupRoute(t *testing.T, enabled bool) (*Controller, *testLine, *testCommander, context.CancelFunc) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	commander := &testCommander{}
	line := &testLine{incoming: make(chan SIPCall, 1), dialed: make(chan string, 1), answer: make(chan SIPCall, 1), registered: true}
	controller, err := New(ctx, call.NewController(commander), line, func() bool { return enabled })
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = controller.Run(ctx) }()
	t.Cleanup(cancel)
	return controller, line, commander, cancel
}

func TestOutgoingWiFiCallRoutesMediaAndDTMF(t *testing.T) {
	controller, line, commander, _ := setupRoute(t, true)
	if err := controller.Dial(context.Background(), "1234"); err != nil {
		t.Fatal(err)
	}
	waitState(t, controller.Events(), call.StateDialing)
	if number := <-line.dialed; number != "1234" {
		t.Fatalf("dialed %q", number)
	}
	endpoint, err := controller.OpenPCM(context.Background(), func(context.Context) (media.DuplexPCM, error) {
		return nil, errors.New("cellular endpoint must not open")
	})
	if err != nil {
		t.Fatal(err)
	}
	writeDone := make(chan error, 1)
	go func() { _, err := endpoint.Write([]byte("voice")); writeDone <- err }()
	dialog := newTestCall("1234")
	line.answer <- dialog
	waitState(t, controller.Events(), call.StateActive)
	if err := <-writeDone; err != nil {
		t.Fatal(err)
	}
	if dialog.pcm.String() != "voice" {
		t.Fatalf("SIP PCM received %q", dialog.pcm.String())
	}
	if err := controller.SendDTMF(context.Background(), "5"); err != nil {
		t.Fatal(err)
	}
	if digit := <-dialog.dtmf; digit != '5' {
		t.Fatalf("DTMF digit %q", digit)
	}
	if err := controller.Hangup(context.Background()); err != nil {
		t.Fatal(err)
	}
	waitState(t, controller.Events(), call.StateEnded)
	if err := controller.Hangup(context.Background()); err != nil {
		t.Fatal(err)
	}
	commander.mu.Lock()
	defer commander.mu.Unlock()
	if len(commander.commands) != 0 {
		t.Fatalf("SIP call used cellular AT commands: %v", commander.commands)
	}
}

func TestIncomingWiFiCallCanNegotiateBeforeAnswer(t *testing.T) {
	controller, line, _, _ := setupRoute(t, true)
	dialog := newTestCall("1234")
	line.incoming <- dialog
	waitState(t, controller.Events(), call.StateRinging)
	endpoint, err := controller.OpenPCM(context.Background(), func(context.Context) (media.DuplexPCM, error) {
		return nil, io.ErrUnexpectedEOF
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := controller.Answer(context.Background()); err != nil {
		t.Fatal(err)
	}
	waitState(t, controller.Events(), call.StateActive)
	if _, err := endpoint.Write([]byte("answer")); err != nil {
		t.Fatal(err)
	}
	if dialog.pcm.String() != "answer" {
		t.Fatalf("incoming SIP PCM received %q", dialog.pcm.String())
	}
	dialog.once.Do(func() { close(dialog.done) })
	waitState(t, controller.Events(), call.StateEnded)
}

func TestCellularFallbackAndUnavailableGateway(t *testing.T) {
	cellular, _, commander, _ := setupRoute(t, false)
	if err := cellular.Dial(context.Background(), "1234"); err != nil {
		t.Fatal(err)
	}
	commander.mu.Lock()
	commands := append([]string(nil), commander.commands...)
	commander.mu.Unlock()
	if len(commands) != 1 || commands[0] != "ATD1234;" {
		t.Fatalf("cellular dial commands: %v", commands)
	}
	wifi, line, fallbackCommander, _ := setupRoute(t, true)
	line.registered = false
	if err := wifi.Dial(context.Background(), "1234"); err != nil {
		t.Fatalf("cellular fallback failed: %v", err)
	}
	fallbackCommander.mu.Lock()
	defer fallbackCommander.mu.Unlock()
	if len(fallbackCommander.commands) != 1 || fallbackCommander.commands[0] != "ATD1234;" {
		t.Fatalf("unregistered gateway did not fall back to cellular: %v", fallbackCommander.commands)
	}
}

func TestCanceledWiFiDialUnblocksMedia(t *testing.T) {
	controller, line, _, _ := setupRoute(t, true)
	if err := controller.Dial(context.Background(), "1234"); err != nil {
		t.Fatal(err)
	}
	<-line.dialed
	endpoint, err := controller.OpenPCM(context.Background(), func(context.Context) (media.DuplexPCM, error) { return nil, nil })
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() { _, err := endpoint.Write([]byte("audio")); result <- err }()
	if err := controller.Hangup(context.Background()); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-result:
		if err == nil {
			t.Fatal("pending PCM did not fail on hangup")
		}
	case <-time.After(time.Second):
		t.Fatal("pending PCM remained blocked after hangup")
	}
}

func TestGatewayFailureDoesNotStopCellularAndReopensLine(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	commander := &testCommander{}
	created := make(chan *testLine, 2)
	controller, err := NewWithFactory(ctx, call.NewController(commander), func() (Line, error) {
		line := &testLine{incoming: make(chan SIPCall, 1), dialed: make(chan string, 1),
			answer: make(chan SIPCall, 1), stop: make(chan error, 1), registered: true}
		created <- line
		return line, nil
	}, func() bool { return false })
	if err != nil {
		t.Fatal(err)
	}
	controller.retryDelay = 10 * time.Millisecond
	result := make(chan error, 1)
	go func() { result <- controller.Run(ctx) }()
	first := <-created
	first.stop <- errors.New("gateway disconnected")
	if err := controller.Dial(context.Background(), "1234"); err != nil {
		t.Fatalf("cellular dial failed while IMS was offline: %v", err)
	}
	select {
	case <-created:
	case <-time.After(time.Second):
		t.Fatal("SIP line was not recreated")
	}
	cancel()
	select {
	case <-result:
	case <-time.After(time.Second):
		t.Fatal("call router did not stop")
	}
}
