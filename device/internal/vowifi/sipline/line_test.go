package sipline

import (
	"context"
	"net"
	"strconv"
	"testing"
	"time"

	"github.com/emiago/diago"
	"github.com/emiago/diago/media"
	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"
)

func freeUDPPort(t *testing.T) int {
	t.Helper()
	listener, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.LocalAddr().(*net.UDPAddr).Port
}

func TestLocalSIPCallCarriesPCMAndHangup(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	port := freeUDPPort(t)
	serverUA, err := sipgo.NewUA()
	if err != nil {
		t.Fatal(err)
	}
	defer serverUA.Close()
	server := diago.NewDiago(serverUA,
		diago.WithTransport(diago.Transport{Transport: "udp", BindHost: "127.0.0.1", BindPort: port}),
		diago.WithMediaConfig(diago.MediaConfig{Codecs: []media.Codec{media.CodecAudioUlaw}}),
	)
	serverResult := make(chan error, 1)
	if err := server.ServeBackground(ctx, func(dialog *diago.DialogServerSession) {
		defer dialog.Close()
		if err := dialog.Trying(); err != nil {
			serverResult <- err
			return
		}
		if err := dialog.Ringing(); err != nil {
			serverResult <- err
			return
		}
		if err := dialog.Answer(); err != nil {
			serverResult <- err
			return
		}
		reader, err := dialog.AudioReader()
		if err != nil {
			serverResult <- err
			return
		}
		buffer := make([]byte, 160)
		_, err = reader.Read(buffer)
		serverResult <- err
		<-dialog.Context().Done()
	}); err != nil {
		t.Fatal(err)
	}
	line, err := New(Config{Registrar: "sip:127.0.0.1:" + strconv.Itoa(port), Username: "simdeck", Password: "local-test", BindHost: "127.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	defer line.Close()
	var ringing bool
	call, err := line.Dial(ctx, "1234", func(status int) {
		if status == 180 {
			ringing = true
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ringing || call.Number() != "1234" || call.PCM() == nil {
		t.Fatalf("SIP call progress or PCM missing: ringing=%v number=%s", ringing, call.Number())
	}
	if _, err := call.PCM().Write(make([]byte, 320)); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-serverResult:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if err := call.Hangup(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case <-call.Done():
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
}

func TestLineRequiresLocalSIPCredentials(t *testing.T) {
	if _, err := New(Config{Registrar: "sip:127.0.0.1:5060", BindHost: "127.0.0.1"}); err == nil {
		t.Fatal("created line without SIP credentials")
	}
}

func TestIncomingLocalSIPCallCanBeAnsweredAndEnded(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	port := freeUDPPort(t)
	line, err := New(Config{Registrar: "sip:127.0.0.1:" + strconv.Itoa(port), Username: "simdeck", Password: "local-test", BindHost: "127.0.0.1", BindPort: port})
	if err != nil {
		t.Fatal(err)
	}
	defer line.Close()
	if err := line.dialogs.ServeBackground(ctx, line.handleIncoming); err != nil {
		t.Fatal(err)
	}
	callerUA, err := sipgo.NewUA()
	if err != nil {
		t.Fatal(err)
	}
	defer callerUA.Close()
	caller := diago.NewDiago(callerUA, diago.WithTransport(diago.Transport{Transport: "udp", BindHost: "127.0.0.1"}),
		diago.WithMediaConfig(diago.MediaConfig{Codecs: []media.Codec{media.CodecAudioUlaw}}))
	result := make(chan *diago.DialogClientSession, 1)
	failures := make(chan error, 1)
	go func() {
		dialog, err := caller.Invite(ctx, sip.Uri{User: "simdeck", Host: "127.0.0.1", Port: port}, diago.InviteOptions{})
		if err != nil {
			failures <- err
			return
		}
		result <- dialog
	}()
	var call *Call
	select {
	case call = <-line.Incoming():
	case err := <-failures:
		t.Fatal(err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if err := call.Answer(); err != nil {
		t.Fatal(err)
	}
	if call.PCM() == nil {
		t.Fatal("answered call has no PCM endpoint")
	}
	select {
	case dialog := <-result:
		defer dialog.Close()
	case err := <-failures:
		t.Fatal(err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if err := call.Hangup(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case <-call.Done():
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
}
