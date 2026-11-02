package route

import (
	"context"

	"sim-deck-device/internal/vowifi/sipline"
)

type localLine struct {
	line     *sipline.Line
	incoming chan SIPCall
}

// NewLocalLine connects the call router to the local IMS gateway SIP account.
func NewLocalLine(config sipline.Config) (Line, error) {
	line, err := sipline.New(config)
	if err != nil {
		return nil, err
	}
	return &localLine{line: line, incoming: make(chan SIPCall, 1)}, nil
}

func (line *localLine) Run(ctx context.Context) error {
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case dialog := <-line.line.Incoming():
				select {
				case line.incoming <- dialog:
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	return line.line.Run(ctx)
}

func (line *localLine) Registered() bool               { return line.line.Registered() }
func (line *localLine) IncomingCalls() <-chan SIPCall { return line.incoming }
func (line *localLine) Close() error                   { return line.line.Close() }
func (line *localLine) DialCall(ctx context.Context, number string, progress func(int)) (SIPCall, error) {
	return line.line.Dial(ctx, number, progress)
}
