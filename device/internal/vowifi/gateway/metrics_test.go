package gateway

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestMetricsRequiresCarrierRegistrationAndTunnel(t *testing.T) {
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
	for _, test := range []struct {
		body   string
		status string
		ready  bool
	}{
		{registeredMetric + "{module=\"vowifi-0\"} 1\n" + tunnelMetric + "{module=\"vowifi-0\"} 1\n", "ims_registered", true},
		{registeredMetric + "{module=\"vowifi-0\"} 1\n" + tunnelMetric + "{module=\"vowifi-0\"} 0\n", "ims_unregistered", false},
		{registeredMetric + "{module=\"vowifi-0\"} 1\n" + tunnelMetric + "{module=\"vowifi-1\"} 1\n", "ims_unregistered", false},
		{registeredMetric + "{module=\"vowifi-0\"} 1\n" + registeredMetric + "{module=\"vowifi-1\"} 1\n" + tunnelMetric + "{module=\"vowifi-0\"} 1\n", "ims_unregistered", false},
	} {
		body = test.body
		status, err := metrics.Probe(context.Background())
		if err != nil || status != test.status || metrics.Ready() != test.ready {
			t.Fatalf("status=%q ready=%v error=%v for %q", status, metrics.Ready(), err, test.body)
		}
	}
	body = registeredMetric + "{module=\"vowifi-0\"} 1\n" + tunnelMetric + "{module=\"vowifi-0\"} 1\n"
	metrics.Invalidate()
	status, err := metrics.Probe(context.Background())
	if err != nil || status != "ims_reconnecting" || metrics.Ready() {
		t.Fatalf("old profile registration reused: status=%q ready=%v err=%v", status, metrics.Ready(), err)
	}
	body = registeredMetric + "{module=\"vowifi-0\"} 0\n" + tunnelMetric + "{module=\"vowifi-0\"} 0\n"
	_, _ = metrics.Probe(context.Background())
	body = registeredMetric + "{module=\"vowifi-0\"} 1\n" + tunnelMetric + "{module=\"vowifi-0\"} 1\n"
	status, err = metrics.Probe(context.Background())
	if err != nil || status != "ims_registered" || !metrics.Ready() {
		t.Fatalf("fresh profile registration rejected: status=%q ready=%v err=%v", status, metrics.Ready(), err)
	}
}

func TestMetricsRejectsRemoteEndpoints(t *testing.T) {
	for _, address := range []string{"http://example.com:9091/metrics", "https://127.0.0.1:9091/metrics", "http://127.0.0.1:9091/other"} {
		if _, err := NewMetrics(address); err == nil {
			t.Fatalf("accepted %q", address)
		}
	}
}
