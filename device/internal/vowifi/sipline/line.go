package sipline

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"sync"
	"sync/atomic"

	"github.com/emiago/diago"
	"github.com/emiago/diago/media"
	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"

	devicemedia "sim-deck-device/internal/media"
	"sim-deck-device/internal/vowifi/sipmedia"
)

var numberPattern = regexp.MustCompile(`^\+?[0-9]{1,20}$`)

// Config identifies a trusted local SIP gateway connected to the carrier IMS.
type Config struct {
	Registrar string
	Username  string
	Password  string
	BindHost  string
	BindPort  int
}

// Line owns the SIP signalling and RTP endpoint for one modem profile.
type Line struct {
	ua         *sipgo.UserAgent
	dialogs    *diago.Diago
	registrar  sip.Uri
	username   string
	password   string
	incoming   chan *Call
	registered atomic.Bool
}

// New creates a SIP line with PCMU, matching the device WebRTC media format.
func New(config Config) (*Line, error) {
	if config.Username == "" || config.Password == "" || config.BindHost == "" || config.BindPort < 0 || config.BindPort > 65535 {
		return nil, errors.New("SIP line requires credentials and a valid local bind address")
	}
	registrar := sip.Uri{}
	if err := sip.ParseUri(config.Registrar, &registrar); err != nil || registrar.Host == "" || registrar.Scheme != "sip" {
		return nil, errors.New("SIP registrar must be a sip: URI with a host")
	}
	ua, err := sipgo.NewUA(sipgo.WithUserAgent(config.Username))
	if err != nil {
		return nil, fmt.Errorf("create SIP user agent: %w", err)
	}
	dialogs := diago.NewDiago(ua,
		diago.WithTransport(diago.Transport{Transport: "udp", BindHost: config.BindHost, BindPort: config.BindPort}),
		diago.WithMediaConfig(diago.MediaConfig{Codecs: []media.Codec{media.CodecAudioUlaw}}),
	)
	return &Line{ua: ua, dialogs: dialogs, registrar: registrar, username: config.Username,
		password: config.Password, incoming: make(chan *Call, 1)}, nil
}

// Incoming yields calls received from the local IMS gateway.
func (line *Line) Incoming() <-chan *Call { return line.incoming }

// Registered reports whether the local SIP account is registered with its gateway.
// Carrier IMS registration is a separate status owned by the gateway.
func (line *Line) Registered() bool { return line.registered.Load() }

// Run receives calls and keeps the local gateway account registered.
func (line *Line) Run(ctx context.Context) error {
	if err := line.dialogs.ServeBackground(ctx, line.handleIncoming); err != nil {
		return fmt.Errorf("listen for IMS gateway calls: %w", err)
	}
	defer line.registered.Store(false)
	err := line.dialogs.Register(ctx, line.registrar, diago.RegisterOptions{
		Username:     line.username,
		Password:     line.password,
		OnRegistered: func() { line.registered.Store(true) },
	})
	if err != nil && !errors.Is(err, context.Canceled) {
		return fmt.Errorf("register with local IMS gateway: %w", err)
	}
	return err
}

// Dial places a call through the local gateway and returns after SIP answer.
func (line *Line) Dial(ctx context.Context, number string, progress func(int)) (*Call, error) {
	if !numberPattern.MatchString(number) {
		return nil, errors.New("phone number must contain only digits and an optional leading plus")
	}
	recipient := line.registrar
	recipient.User = number
	dialog, err := line.dialogs.Invite(ctx, recipient, diago.InviteOptions{
		Username: line.username,
		Password: line.password,
		OnResponse: func(response *sip.Response) error {
			if progress != nil {
				progress(response.StatusCode)
			}
			return nil
		},
	})
	if err != nil {
		return nil, fmt.Errorf("place IMS gateway call: %w", err)
	}
	endpoint, err := sipmedia.FromDialog(&dialog.DialogMedia)
	if err != nil {
		_ = dialog.Hangup(ctx)
		_ = dialog.Close()
		return nil, err
	}
	call := &Call{outgoing: dialog, media: endpoint, number: number, done: make(chan struct{})}
	go call.watch(dialog.Context().Done())
	return call, nil
}

func (line *Line) handleIncoming(dialog *diago.DialogServerSession) {
	defer dialog.Close()
	if err := dialog.Trying(); err != nil {
		return
	}
	if err := dialog.Ringing(); err != nil {
		return
	}
	call := &Call{incoming: dialog, number: dialog.FromUser(), done: make(chan struct{})}
	select {
	case line.incoming <- call:
	case <-dialog.Context().Done():
		return
	default:
		_ = dialog.Respond(sip.StatusBusyHere, "Busy Here", nil)
		return
	}
	select {
	case <-call.done:
	case <-dialog.Context().Done():
		call.finish()
	}
}

// Call owns one SIP dialog and its call-scoped PCM media.
type Call struct {
	incoming *diago.DialogServerSession
	outgoing *diago.DialogClientSession
	number   string
	media    *sipmedia.Duplex
	mu       sync.Mutex
	once     sync.Once
	done     chan struct{}
}

func (call *Call) Number() string        { return call.number }
func (call *Call) Done() <-chan struct{} { return call.done }
func (call *Call) PCM() devicemedia.DuplexPCM {
	call.mu.Lock()
	defer call.mu.Unlock()
	return call.media
}

// SendDTMF sends one telephone event over the established SIP media session.
func (call *Call) SendDTMF(digit rune) error {
	if digit != '*' && digit != '#' && (digit < '0' || digit > '9') {
		return errors.New("DTMF digit must be 0-9, star, or hash")
	}
	call.mu.Lock()
	defer call.mu.Unlock()
	if call.media == nil {
		return errors.New("SIP call media is not active")
	}
	var dialog *diago.DialogMedia
	if call.incoming != nil {
		dialog = &call.incoming.DialogMedia
	} else {
		dialog = &call.outgoing.DialogMedia
	}
	writer, err := dialog.AudioWriterDTMF()
	if err != nil {
		return fmt.Errorf("open SIP DTMF writer: %w", err)
	}
	return writer.WriteDTMF(digit)
}

// Answer accepts an incoming SIP call and makes its PCM stream available.
func (call *Call) Answer() error {
	call.mu.Lock()
	defer call.mu.Unlock()
	if call.incoming == nil || call.media != nil {
		return errors.New("call is not an unanswered incoming SIP dialog")
	}
	if err := call.incoming.Answer(); err != nil {
		return fmt.Errorf("answer IMS gateway call: %w", err)
	}
	endpoint, err := sipmedia.FromDialog(&call.incoming.DialogMedia)
	if err != nil {
		_ = call.incoming.Hangup(call.incoming.Context())
		return err
	}
	call.media = endpoint
	return nil
}

// Hangup ends either direction of SIP dialog and releases RTP resources.
func (call *Call) Hangup(ctx context.Context) error {
	var err error
	if call.incoming != nil {
		err = call.incoming.Hangup(ctx)
	} else if call.outgoing != nil {
		err = call.outgoing.Hangup(ctx)
	}
	call.finish()
	return err
}

func (call *Call) watch(done <-chan struct{}) {
	select {
	case <-done:
		call.finish()
	case <-call.done:
	}
}

func (call *Call) finish() {
	call.once.Do(func() {
		call.mu.Lock()
		endpoint := call.media
		call.mu.Unlock()
		if endpoint != nil {
			_ = endpoint.Close()
		}
		if call.outgoing != nil {
			_ = call.outgoing.Close()
		}
		close(call.done)
	})
}

// Close releases the SIP user agent after Run has stopped.
func (line *Line) Close() error { return line.ua.Close() }
