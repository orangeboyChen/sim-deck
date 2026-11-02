package gateway

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const registeredMetric = "gsm_sip_bridge_vowifi_registered"
const tunnelMetric = "gsm_sip_bridge_vowifi_tunnel_up"

// Metrics reads the companion's carrier IMS and ePDG state. The local SIP
// registration alone is not evidence that Wi-Fi Calling works.
type Metrics struct {
	url       string
	client    *http.Client
	ready     atomic.Bool
	awaitDown atomic.Bool
}

func NewMetrics(rawURL string) (*Metrics, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Scheme != "http" || parsed.Path != "/metrics" || parsed.RawQuery != "" {
		return nil, errors.New("Wi-Fi Calling metrics URL must be an HTTP /metrics endpoint")
	}
	host := parsed.Hostname()
	if host != "localhost" && (net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback()) {
		return nil, errors.New("Wi-Fi Calling metrics endpoint must be on loopback")
	}
	if parsed.Port() == "" {
		return nil, errors.New("Wi-Fi Calling metrics URL requires a port")
	}
	return &Metrics{url: rawURL, client: &http.Client{Timeout: 2 * time.Second}}, nil
}

func (metrics *Metrics) Ready() bool { return metrics.ready.Load() }

// Invalidate prevents a prior eSIM profile's registration from authorizing
// calls until the companion reports a down transition and a fresh registration.
func (metrics *Metrics) Invalidate() {
	metrics.ready.Store(false)
	metrics.awaitDown.Store(true)
}

// Probe updates the cached readiness only after observing both a carrier IMS
// registration and an ePDG tunnel for the same single companion line.
func (metrics *Metrics) Probe(ctx context.Context) (string, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, metrics.url, nil)
	if err != nil {
		metrics.ready.Store(false)
		return "backend_unavailable", err
	}
	response, err := metrics.client.Do(request)
	if err != nil {
		metrics.ready.Store(false)
		return "backend_unavailable", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		metrics.ready.Store(false)
		return "backend_unavailable", fmt.Errorf("IMS companion metrics returned HTTP %d", response.StatusCode)
	}
	values := map[string]map[string]bool{registeredMetric: {}, tunnelMetric: {}}
	scanner := bufio.NewScanner(io.LimitReader(response.Body, 1<<20))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		for name := range values {
			if !strings.HasPrefix(line, name+"{") {
				continue
			}
			closing := strings.IndexByte(line, '}')
			if closing < 0 {
				continue
			}
			labels := line[len(name)+1 : closing]
			module := ""
			for _, label := range strings.Split(labels, ",") {
				if strings.HasPrefix(label, "module=") {
					module = strings.Trim(strings.TrimPrefix(label, "module="), `"`)
				}
			}
			if module == "" {
				continue
			}
			value, parseErr := strconv.ParseFloat(strings.TrimSpace(line[closing+1:]), 64)
			if parseErr == nil {
				values[name][module] = value == 1
			}
		}
	}
	if err := scanner.Err(); err != nil {
		metrics.ready.Store(false)
		return "backend_unavailable", err
	}
	registered := values[registeredMetric]
	tunnel := values[tunnelMetric]
	if len(registered) != 1 || len(tunnel) != 1 {
		metrics.ready.Store(false)
		return "ims_unregistered", nil
	}
	for module, active := range registered {
		ready := active && tunnel[module]
		if !ready {
			metrics.awaitDown.Store(false)
		}
		if ready && metrics.awaitDown.Load() {
			metrics.ready.Store(false)
			return "ims_reconnecting", nil
		}
		metrics.ready.Store(ready)
		if ready {
			return "ims_registered", nil
		}
	}
	return "ims_unregistered", nil
}

func (metrics *Metrics) Run(ctx context.Context) error {
	_, _ = metrics.Probe(ctx)
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			metrics.ready.Store(false)
			return ctx.Err()
		case <-ticker.C:
			_, _ = metrics.Probe(ctx)
		}
	}
}
