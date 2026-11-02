package sipmedia

import (
	"bytes"
	"io"
	"testing"
)

type closeCounter struct{ count int }

func (counter *closeCounter) Close() error {
	counter.count++
	return nil
}

func TestPCMUAndPCMFlowInBothDirections(t *testing.T) {
	inbound := bytes.NewReader(bytes.Repeat([]byte{0xff}, 160))
	var outbound bytes.Buffer
	closer := &closeCounter{}
	duplex, err := newDuplex(inbound, &outbound, closer)
	if err != nil {
		t.Fatal(err)
	}
	first := make([]byte, 100)
	second := make([]byte, 220)
	if n, err := duplex.Read(first); err != nil || n != len(first) {
		t.Fatalf("first PCM read = %d, %v", n, err)
	}
	if n, err := duplex.Read(second); err != nil || n != len(second) {
		t.Fatalf("second PCM read = %d, %v", n, err)
	}
	if !bytes.Equal(append(first, second...), make([]byte, 320)) {
		t.Fatal("PCMU silence did not decode to PCM silence")
	}
	if n, err := duplex.Write(make([]byte, 100)); err != nil || n != 100 || outbound.Len() != 0 {
		t.Fatalf("partial PCM write = %d, %v, encoded bytes = %d", n, err, outbound.Len())
	}
	if n, err := duplex.Write(make([]byte, 220)); err != nil || n != 220 {
		t.Fatalf("completed PCM write = %d, %v", n, err)
	}
	if !bytes.Equal(outbound.Bytes(), bytes.Repeat([]byte{0xff}, 160)) {
		t.Fatalf("encoded PCMU frame = %x", outbound.Bytes())
	}
	if err := duplex.Close(); err != nil {
		t.Fatal(err)
	}
	if err := duplex.Close(); err != nil || closer.count != 1 {
		t.Fatalf("close result = %v, count = %d", err, closer.count)
	}
	if _, err := duplex.Read(make([]byte, 320)); err != io.EOF {
		t.Fatalf("read after inbound end = %v", err)
	}
}
