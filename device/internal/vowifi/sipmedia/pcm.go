package sipmedia

import (
	"errors"
	"fmt"
	"io"
	"sync"

	"github.com/emiago/diago"
	"github.com/emiago/diago/audio"
)

const pcmFrameBytes = 320

// Duplex adapts one negotiated PCMU SIP/RTP session to the device's 8 kHz,
// signed 16-bit PCM media endpoint.
type Duplex struct {
	decoder *audio.PCMDecoderReader
	encoder *audio.PCMEncoderWriter
	closer  io.Closer

	readMu       sync.Mutex
	readPending  []byte
	writeMu      sync.Mutex
	writePending []byte
	closeOnce    sync.Once
	closeError   error
}

// FromDialog opens the negotiated SIP media as a full-duplex PCM endpoint.
func FromDialog(dialog *diago.DialogMedia) (*Duplex, error) {
	if dialog == nil {
		return nil, errors.New("SIP media dialog is required")
	}
	props := diago.MediaProps{}
	reader, err := dialog.AudioReader(diago.WithAudioReaderMediaProps(&props))
	if err != nil {
		return nil, fmt.Errorf("open SIP audio reader: %w", err)
	}
	if props.Codec.PayloadType != 0 {
		return nil, fmt.Errorf("SIP media must negotiate PCMU, got payload type %d", props.Codec.PayloadType)
	}
	writer, err := dialog.AudioWriter()
	if err != nil {
		return nil, fmt.Errorf("open SIP audio writer: %w", err)
	}
	return newDuplex(reader, writer, dialog)
}

func newDuplex(reader io.Reader, writer io.Writer, closer io.Closer) (*Duplex, error) {
	decoder, err := audio.NewPCMDecoderReader(0, reader)
	if err != nil {
		return nil, fmt.Errorf("decode PCMU: %w", err)
	}
	encoder, err := audio.NewPCMEncoderWriter(0, writer)
	if err != nil {
		return nil, fmt.Errorf("encode PCMU: %w", err)
	}
	return &Duplex{decoder: decoder, encoder: encoder, closer: closer}, nil
}

// Read returns decoded PCM without dropping the rest of a large RTP packet.
func (duplex *Duplex) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	duplex.readMu.Lock()
	defer duplex.readMu.Unlock()
	if len(duplex.readPending) == 0 {
		buffer := make([]byte, 8192)
		n, err := duplex.decoder.Read(buffer)
		if err != nil {
			return 0, err
		}
		duplex.readPending = buffer[:n]
	}
	n := copy(p, duplex.readPending)
	duplex.readPending = duplex.readPending[n:]
	return n, nil
}

// Write packetizes PCM into 20 ms PCMU frames for the SIP RTP writer.
func (duplex *Duplex) Write(p []byte) (int, error) {
	duplex.writeMu.Lock()
	defer duplex.writeMu.Unlock()
	duplex.writePending = append(duplex.writePending, p...)
	for len(duplex.writePending) >= pcmFrameBytes {
		if _, err := duplex.encoder.Write(duplex.writePending[:pcmFrameBytes]); err != nil {
			return 0, err
		}
		duplex.writePending = duplex.writePending[pcmFrameBytes:]
	}
	return len(p), nil
}

// Close releases the RTP media endpoint.
func (duplex *Duplex) Close() error {
	duplex.closeOnce.Do(func() {
		if duplex.closer != nil {
			duplex.closeError = duplex.closer.Close()
		}
	})
	return duplex.closeError
}
