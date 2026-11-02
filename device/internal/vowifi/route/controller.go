package route

import (
	"context"
	"errors"
	"fmt"
	"io"
	"regexp"
	"sync"

	"sim-deck-device/internal/call"
	"sim-deck-device/internal/media"
)

var numberPattern = regexp.MustCompile(`^\+?[0-9]{1,20}$`)

// SIPCall is one call managed by the local IMS gateway.
type SIPCall interface {
	Number() string
	Done() <-chan struct{}
	PCM() media.DuplexPCM
	Answer() error
	Hangup(context.Context) error
	SendDTMF(rune) error
}

// Line is the gateway interface accepted by Controller. Its incoming stream
// uses callbacks so a SIP implementation can keep ownership of its dialog.
type Line interface {
	Run(context.Context) error
	Registered() bool
	IncomingCalls() <-chan SIPCall
	DialCall(context.Context, string, func(int)) (SIPCall, error)
	Close() error
}

type session struct {
	call   SIPCall
	cancel context.CancelFunc
	ready  chan struct{}
	err    error
	mu     sync.Mutex
	once   sync.Once
}

func (session *session) resolve(call SIPCall, err error) {
	session.once.Do(func() {
		session.mu.Lock()
		session.call, session.err = call, err
		session.mu.Unlock()
		close(session.ready)
	})
}

func (session *session) endpoint(ctx context.Context, closed <-chan struct{}) (media.DuplexPCM, error) {
	select {
	case <-session.ready:
	case <-closed:
		return nil, io.ErrClosedPipe
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.err != nil {
		return nil, session.err
	}
	if session.call == nil || session.call.PCM() == nil {
		return nil, errors.New("SIP media is not active")
	}
	return session.call.PCM(), nil
}

// Controller routes a slot's calls through either cellular voice or its
// registered Wi-Fi Calling gateway and emits a single call-state stream.
type Controller struct {
	cellular *call.Controller
	line     Line
	enabled  func() bool
	lifetime context.Context

	mu          sync.RWMutex
	active      *session
	snapshot    call.Snapshot
	events      chan call.Snapshot
	subscribers []chan call.Snapshot
}

func New(ctx context.Context, cellular *call.Controller, line Line, enabled func() bool) (*Controller, error) {
	if ctx == nil || cellular == nil || line == nil || enabled == nil {
		return nil, errors.New("call route requires a lifetime, cellular controller, SIP line, and policy")
	}
	return &Controller{cellular: cellular, line: line, enabled: enabled, lifetime: ctx,
		snapshot: cellular.Snapshot(), events: make(chan call.Snapshot, 32)}, nil
}

func (controller *Controller) Events() <-chan call.Snapshot { return controller.events }

func (controller *Controller) Subscribe() <-chan call.Snapshot {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	stream := make(chan call.Snapshot, 32)
	controller.subscribers = append(controller.subscribers, stream)
	return stream
}

func (controller *Controller) Snapshot() call.Snapshot {
	controller.mu.RLock()
	defer controller.mu.RUnlock()
	return controller.snapshot
}

func (controller *Controller) State() call.State { return controller.Snapshot().State }

func (controller *Controller) publish(snapshot call.Snapshot) {
	controller.mu.Lock()
	if controller.snapshot == snapshot {
		controller.mu.Unlock()
		return
	}
	controller.snapshot = snapshot
	subscribers := append([]chan call.Snapshot(nil), controller.subscribers...)
	controller.mu.Unlock()
	controller.events <- snapshot
	for _, subscriber := range subscribers {
		subscriber <- snapshot
	}
}

// Run combines cellular events and SIP dialogs until the device stops.
func (controller *Controller) Run(ctx context.Context) error {
	defer controller.line.Close()
	lineResult := make(chan error, 1)
	go func() { lineResult <- controller.line.Run(ctx) }()
	cellularEvents := controller.cellular.Events()
	for {
		select {
		case <-ctx.Done():
			controller.endActive(context.WithoutCancel(ctx))
			return ctx.Err()
		case err := <-lineResult:
			controller.endActive(context.WithoutCancel(ctx))
			return fmt.Errorf("IMS gateway line stopped: %w", err)
		case snapshot := <-cellularEvents:
			controller.mu.RLock()
			busy := controller.active != nil
			controller.mu.RUnlock()
			if !busy {
				controller.publish(snapshot)
			} else if snapshot.State == call.StateRinging || snapshot.State == call.StateWaiting {
				_ = controller.cellular.Reject(ctx)
			}
		case incoming := <-controller.line.IncomingCalls():
			controller.mu.Lock()
			if controller.active != nil || !controller.enabled() ||
				(controller.cellular.State() != call.StateIdle && controller.cellular.State() != call.StateEnded) {
				controller.mu.Unlock()
				_ = incoming.Hangup(ctx)
				continue
			}
			item := &session{call: incoming, ready: make(chan struct{})}
			controller.active = item
			controller.mu.Unlock()
			controller.publish(call.Snapshot{State: call.StateRinging, IncomingNumber: incoming.Number()})
			go controller.watch(item, incoming)
		}
	}
}

func (controller *Controller) Dial(ctx context.Context, number string) error {
	if !controller.enabled() {
		return controller.cellular.Dial(ctx, number)
	}
	if !controller.line.Registered() {
		return errors.New("Wi-Fi Calling gateway is not registered")
	}
	if controller.cellular.State() != call.StateIdle && controller.cellular.State() != call.StateEnded {
		return errors.New("cellular call is already in progress")
	}
	if !numberPattern.MatchString(number) {
		return errors.New("invalid phone number")
	}
	controller.mu.Lock()
	if controller.active != nil {
		controller.mu.Unlock()
		return errors.New("Wi-Fi Calling call is already in progress")
	}
	dialContext, cancel := context.WithCancel(controller.lifetime)
	item := &session{cancel: cancel, ready: make(chan struct{})}
	controller.active = item
	controller.mu.Unlock()
	controller.publish(call.Snapshot{State: call.StateDialing})
	go func() {
		dialog, err := controller.line.DialCall(dialContext, number, func(status int) {
			if status == 180 || status == 183 {
				controller.publish(call.Snapshot{State: call.StateDialing})
			}
		})
		if err != nil {
			item.resolve(nil, err)
			controller.finish(item)
			return
		}
		controller.mu.RLock()
		current := controller.active == item
		controller.mu.RUnlock()
		if !current {
			_ = dialog.Hangup(context.Background())
			return
		}
		item.resolve(dialog, nil)
		controller.publish(call.Snapshot{State: call.StateActive, Active: true})
		controller.watch(item, dialog)
	}()
	return nil
}

func (controller *Controller) watch(item *session, dialog SIPCall) {
	select {
	case <-dialog.Done():
	case <-controller.lifetime.Done():
	}
	controller.finish(item)
}

func (controller *Controller) finish(item *session) {
	item.resolve(nil, io.ErrClosedPipe)
	controller.mu.Lock()
	if controller.active != item {
		controller.mu.Unlock()
		return
	}
	controller.active = nil
	controller.mu.Unlock()
	controller.publish(call.Snapshot{State: call.StateEnded})
}

func (controller *Controller) current() *session {
	controller.mu.RLock()
	defer controller.mu.RUnlock()
	return controller.active
}

func (controller *Controller) Answer(ctx context.Context) error {
	item := controller.current()
	if item == nil {
		return controller.cellular.Answer(ctx)
	}
	if item.call == nil {
		return errors.New("outgoing Wi-Fi Calling call cannot be answered locally")
	}
	if err := item.call.Answer(); err != nil {
		controller.finish(item)
		return err
	}
	item.resolve(item.call, nil)
	controller.publish(call.Snapshot{State: call.StateActive, Active: true})
	return nil
}

func (controller *Controller) AnswerWaiting(ctx context.Context) error {
	if controller.current() != nil {
		return errors.New("Wi-Fi Calling does not support call waiting")
	}
	return controller.cellular.AnswerWaiting(ctx)
}

func (controller *Controller) Reject(ctx context.Context) error {
	if controller.current() == nil {
		return controller.cellular.Reject(ctx)
	}
	return controller.endActive(ctx)
}

func (controller *Controller) Hangup(ctx context.Context) error {
	if controller.current() == nil {
		return controller.cellular.Hangup(ctx)
	}
	return controller.endActive(ctx)
}

func (controller *Controller) endActive(ctx context.Context) error {
	item := controller.current()
	if item == nil {
		return nil
	}
	if item.cancel != nil {
		item.cancel()
	}
	var err error
	if item.call != nil {
		err = item.call.Hangup(ctx)
	}
	controller.finish(item)
	return err
}

// InvalidateProfile ends only the SIP call associated with a replaced SIM
// profile. Cellular calls remain under the modem controller's ownership.
func (controller *Controller) InvalidateProfile(ctx context.Context) error {
	return controller.endActive(ctx)
}

func (controller *Controller) Refresh(ctx context.Context) error {
	if controller.current() != nil {
		return nil
	}
	return controller.cellular.Refresh(ctx)
}

func (controller *Controller) AddParticipant(ctx context.Context, number string) error {
	if controller.current() != nil {
		return errors.New("Wi-Fi Calling does not support adding participants")
	}
	return controller.cellular.AddParticipant(ctx, number)
}

func (controller *Controller) Merge(ctx context.Context) error {
	if controller.current() != nil {
		return errors.New("Wi-Fi Calling does not support merging calls")
	}
	return controller.cellular.Merge(ctx)
}

func (controller *Controller) Hold(ctx context.Context) error {
	if controller.current() != nil {
		return errors.New("Wi-Fi Calling does not support hold")
	}
	return controller.cellular.Hold(ctx)
}

func (controller *Controller) Resume(ctx context.Context) error {
	if controller.current() != nil {
		return errors.New("Wi-Fi Calling does not support resume")
	}
	return controller.cellular.Resume(ctx)
}

func (controller *Controller) Swap(ctx context.Context) error {
	if controller.current() != nil {
		return errors.New("Wi-Fi Calling does not support swap")
	}
	return controller.cellular.Swap(ctx)
}

func (controller *Controller) SendDTMF(ctx context.Context, digit string) error {
	item := controller.current()
	if item == nil {
		return controller.cellular.SendDTMF(ctx, digit)
	}
	if len(digit) != 1 || item.call == nil || controller.State() != call.StateActive {
		return errors.New("Wi-Fi Calling call is not active")
	}
	return item.call.SendDTMF(rune(digit[0]))
}

// OpenPCM returns the selected call's PCM endpoint. A SIP endpoint waits for
// the remote answer, allowing WebRTC negotiation before SIP is established.
func (controller *Controller) OpenPCM(ctx context.Context, cellular media.EndpointFactory) (media.DuplexPCM, error) {
	item := controller.current()
	if item == nil {
		return cellular(ctx)
	}
	return &deferredPCM{session: item, closed: make(chan struct{})}, nil
}

type deferredPCM struct {
	session *session
	closed  chan struct{}
	once    sync.Once
}

func (endpoint *deferredPCM) Read(p []byte) (int, error) {
	pcm, err := endpoint.session.endpoint(context.Background(), endpoint.closed)
	if err != nil {
		return 0, err
	}
	return pcm.Read(p)
}

func (endpoint *deferredPCM) Write(p []byte) (int, error) {
	pcm, err := endpoint.session.endpoint(context.Background(), endpoint.closed)
	if err != nil {
		return 0, err
	}
	return pcm.Write(p)
}

func (endpoint *deferredPCM) Close() error {
	endpoint.once.Do(func() { close(endpoint.closed) })
	return nil
}
