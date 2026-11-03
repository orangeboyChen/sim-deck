package gateway

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"syscall"
	"testing"
)

func TestMetricsRequiresCarrierRegistrationAndHealthyTransport(t *testing.T) {
	body := ""
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/metrics" {
			t.Errorf("unexpected path %q", request.URL.Path)
		}
		_, _ = fmt.Fprint(writer, body)
	}))
	defer server.Close()
	metrics, err := NewMetrics(server.URL + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	line := func(registered, tunnel, childSA, gm int) string {
		return fmt.Sprintf("%s{module=\"vowifi-0\"} %d\n%s{module=\"vowifi-0\"} %d\n%s{module=\"vowifi-0\"} %d\n%s{module=\"vowifi-0\"} %d\n",
			registeredMetric, registered, tunnelMetric, tunnel, childSAMetric, childSA, gmMetric, gm)
	}
	for _, test := range []struct {
		body   string
		status string
		ready  bool
	}{
		{line(1, 1, 1, 1), "ims_registered", true},
		{line(0, 1, 1, 1), "ims_unregistered", false},
		{line(1, 0, 1, 1), "ims_transport_unavailable", false},
		{line(1, 1, 0, 1), "ims_transport_unavailable", false},
		{line(1, 1, 1, 0), "ims_transport_unavailable", false},
		{registeredMetric + "{module=\"vowifi-0\"} 1\n" + tunnelMetric + "{module=\"vowifi-0\"} 1\n", "ims_transport_unavailable", false},
		{line(1, 1, 1, 1) + childSAMetric + "{module=\"vowifi-1\"} 1\n", "ims_transport_unavailable", false},
		{registeredMetric + "{module=\"vowifi-0\"} 1\n" + tunnelMetric + "{module=\"vowifi-1\"} 1\n" + childSAMetric + "{module=\"vowifi-0\"} 1\n" + gmMetric + "{module=\"vowifi-0\"} 1\n", "ims_transport_unavailable", false},
	} {
		body = test.body
		status, err := metrics.Probe(context.Background())
		if err != nil || status != test.status || metrics.Status() != test.status || metrics.Ready() != test.ready {
			t.Fatalf("status=%q cached=%q ready=%v error=%v for %q", status, metrics.Status(), metrics.Ready(), err, test.body)
		}
	}
	body = line(1, 1, 1, 1)
	metrics.Invalidate()
	if metrics.Status() != "ims_reconnecting" {
		t.Fatalf("invalidated profile kept status %q", metrics.Status())
	}
	status, err := metrics.Probe(context.Background())
	if err != nil || status != "ims_reconnecting" || metrics.Ready() {
		t.Fatalf("old profile registration reused: status=%q ready=%v err=%v", status, metrics.Ready(), err)
	}
	body = line(0, 0, 0, 0)
	_, _ = metrics.Probe(context.Background())
	body = line(1, 1, 1, 1)
	status, err = metrics.Probe(context.Background())
	if err != nil || status != "ims_registered" || !metrics.Ready() {
		t.Fatalf("fresh profile registration rejected: status=%q ready=%v err=%v", status, metrics.Ready(), err)
	}
}

func TestProfileInvalidationWinsAnInFlightMetricsProbe(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		close(entered)
		<-release
		_, _ = fmt.Fprintf(writer, "%s{module=\"vowifi-0\"} 1\n%s{module=\"vowifi-0\"} 1\n%s{module=\"vowifi-0\"} 1\n%s{module=\"vowifi-0\"} 1\n",
			registeredMetric, tunnelMetric, childSAMetric, gmMetric)
	}))
	defer server.Close()
	metrics, err := NewMetrics(server.URL + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	probeDone := make(chan struct{})
	go func() {
		defer close(probeDone)
		_, _ = metrics.Probe(context.Background())
	}()
	<-entered
	invalidated := make(chan struct{})
	go func() {
		metrics.Invalidate()
		close(invalidated)
	}()
	close(release)
	<-probeDone
	<-invalidated
	if metrics.Ready() || metrics.Status() != "ims_reconnecting" {
		t.Fatalf("old profile remained ready after invalidation: ready=%v status=%q", metrics.Ready(), metrics.Status())
	}
}

func TestMetricsRejectsRemoteEndpoints(t *testing.T) {
	for _, address := range []string{"http://example.com:9091/metrics", "https://127.0.0.1:9091/metrics", "http://127.0.0.1:9091/other"} {
		if _, err := NewMetrics(address); err == nil {
			t.Fatalf("accepted %q", address)
		}
	}
}

func TestMetricsAcceptsFreshRegistrationAfterCompanionRestart(t *testing.T) {
	body := fmt.Sprintf("%s{module=\"vowifi-0\"} 1\n%s{module=\"vowifi-0\"} 1\n%s{module=\"vowifi-0\"} 1\n%s{module=\"vowifi-0\"} 1\n",
		registeredMetric, tunnelMetric, childSAMetric, gmMetric)
	serve := func() *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
			_, _ = fmt.Fprint(writer, body)
		}))
	}
	server := serve()
	metrics, err := NewMetrics(server.URL + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := metrics.Probe(context.Background()); err != nil || !metrics.Ready() {
		t.Fatalf("initial registration unavailable: %v", err)
	}
	metrics.Invalidate()
	server.Close()
	if _, err := metrics.Probe(context.Background()); !errors.Is(err, syscall.ECONNREFUSED) {
		t.Fatalf("expected refused local connection during restart, got %v", err)
	}
	server = serve()
	defer server.Close()
	metrics.url = server.URL + "/metrics"
	status, err := metrics.Probe(context.Background())
	if err != nil || status != "ims_registered" || !metrics.Ready() {
		t.Fatalf("fresh registration after restart rejected: status=%q ready=%v error=%v", status, metrics.Ready(), err)
	}
}
