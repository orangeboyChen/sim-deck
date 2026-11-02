package slotpolicy

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"sim-deck-device/internal/at"
)

type fakeCommander struct {
	commands []string
	response at.Response
	err      error
}

func (commander *fakeCommander) Send(_ context.Context, command string) (at.Response, error) {
	commander.commands = append(commander.commands, command)
	return commander.response, commander.err
}

var _ = Describe("Slot policy controller", func() {
	var commander *fakeCommander
	var directory string

	BeforeEach(func() {
		commander = &fakeCommander{response: at.Response{Terminal: "OK"}}
		directory = GinkgoT().TempDir()
	})

	It("defaults every service on while leaving airplane mode off", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		Expect(controller.Current()).To(Equal(Settings{
			DataEnabled: true, IncomingCallsEnabled: true, IncomingSMSEnabled: true,
		}))
	})

	It("persists incoming service policy without sending radio commands", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		disabled := false
		settings, err := controller.Configure(context.Background(), Update{
			IncomingCallsEnabled: &disabled,
			IncomingSMSEnabled:   &disabled,
		})
		Expect(err).NotTo(HaveOccurred())
		Expect(settings.IncomingCallsEnabled).To(BeFalse())
		Expect(settings.IncomingSMSEnabled).To(BeFalse())
		Expect(commander.commands).To(BeEmpty())

		reloaded, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		Expect(reloaded.Current()).To(Equal(settings))
		info, err := os.Stat(filepath.Join(directory, "slot-policy.json"))
		Expect(err).NotTo(HaveOccurred())
		Expect(info.Mode().Perm()).To(Equal(os.FileMode(0o600)))
	})

	It("persists VoLTE preference after the modem accepts the IMS setting", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		enabled := true

		settings, err := controller.Configure(context.Background(), Update{VoLTEEnabled: &enabled})

		Expect(err).NotTo(HaveOccurred())
		Expect(settings.VoLTEEnabled).To(BeTrue())
		Expect(commander.commands).To(Equal([]string{`AT+QCFG="ims",1`}))
		reloaded, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		Expect(reloaded.Current().VoLTEEnabled).To(BeTrue())
	})

	It("migrates existing slot preferences to the first active eSIM profile", func() {
		path := filepath.Join(directory, "slot-policy.json")
		Expect(os.WriteFile(path, []byte(`{"version":1,"data_enabled":false,"incoming_calls_enabled":true,"incoming_sms_enabled":true,"volte_enabled":true}`), 0o600)).To(Succeed())
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())

		Expect(controller.SelectProfile(context.Background(), "89000000000000000001")).To(Succeed())
		Expect(controller.Profile("89000000000000000001").DataEnabled).To(BeFalse())
		Expect(controller.Profile("89000000000000000001").VoLTEEnabled).To(BeTrue())
		Expect(commander.commands).To(BeEmpty())
	})

	It("keeps eSIM preferences separate and applies only the active profile", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		first, second := "89000000000000000001", "89000000000000000002"
		Expect(controller.SelectProfile(context.Background(), first)).To(Succeed())
		enabled, disabled := true, false
		_, err = controller.ConfigureProfile(context.Background(), first, Update{VoLTEEnabled: &enabled, DataEnabled: &disabled})
		Expect(err).NotTo(HaveOccurred())
		Expect(commander.commands).To(Equal([]string{`AT+QCFG="ims",1`}))
		_, err = controller.ConfigureProfile(context.Background(), second, Update{WiFiCallingEnabled: &enabled})
		Expect(err).NotTo(HaveOccurred())
		Expect(commander.commands).To(HaveLen(1))
		Expect(controller.Profile(second).WiFiCallingStatus).To(Equal("inactive_profile"))
		Expect(controller.SelectProfile(context.Background(), second)).To(Succeed())
		Expect(controller.Current().DataEnabled).To(BeTrue())
		Expect(controller.Current().WiFiCallingEnabled).To(BeTrue())
		Expect(controller.Current().WiFiCallingStatus).To(Equal("not_checked"))
		Expect(commander.commands).To(Equal([]string{`AT+QCFG="ims",1`, `AT+QCFG="ims",0`}))

		reloaded, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		Expect(reloaded.Profile(first).DataEnabled).To(BeFalse())
		Expect(reloaded.Profile(first).VoLTEEnabled).To(BeTrue())
		Expect(reloaded.Profile(second).WiFiCallingEnabled).To(BeTrue())
		Expect(reloaded.Current()).To(Equal(controller.Current()))
	})

	It("clears the deleted active profile and restores default policy", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		profileID := "89000000000000000001"
		Expect(controller.SelectProfile(context.Background(), profileID)).To(Succeed())
		enabled := true
		_, err = controller.ConfigureProfile(context.Background(), profileID, Update{VoLTEEnabled: &enabled})
		Expect(err).NotTo(HaveOccurred())
		Expect(controller.ForgetProfile(profileID)).To(Succeed())
		Expect(controller.SelectProfile(context.Background(), "")).To(Succeed())
		Expect(controller.Current()).To(Equal(defaultSettings()))
		Expect(controller.Profile(profileID)).To(Equal(defaultSettings()))
		Expect(commander.commands).To(Equal([]string{`AT+QCFG="ims",1`, `AT+QCFG="ims",0`}))
	})

	It("reports gateway discovery without claiming VoWiFi registration", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		commander.response = at.Response{Lines: []string{"460001234567890"}, Terminal: "OK"}
		var names []string
		controller.lookupIP = func(_ context.Context, name string) ([]net.IPAddr, error) {
			names = append(names, name)
			return []net.IPAddr{{IP: net.ParseIP("192.0.2.1")}}, nil
		}
		enabled := true
		settings, err := controller.Configure(context.Background(), Update{WiFiCallingEnabled: &enabled})
		Expect(err).NotTo(HaveOccurred())
		Expect(settings.WiFiCallingStatus).To(Equal("gateway_found"))
		Expect(names).To(Equal([]string{"epdg.epc.mnc001.mcc460.pub.3gppnetwork.org"}))
		Expect(commander.commands).To(Equal([]string{"AT+CIMI"}))
	})

	It("does not call a missing gateway an unsupported carrier", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		commander.response = at.Response{Lines: []string{"460001234567890"}, Terminal: "OK"}
		var names []string
		controller.lookupIP = func(_ context.Context, name string) ([]net.IPAddr, error) {
			names = append(names, name)
			return nil, &net.DNSError{Err: "no such host", Name: name, IsNotFound: true}
		}
		enabled := true
		settings, err := controller.Configure(context.Background(), Update{WiFiCallingEnabled: &enabled})
		Expect(err).NotTo(HaveOccurred())
		Expect(settings.WiFiCallingStatus).To(Equal("gateway_not_found"))
		Expect(names).To(Equal([]string{
			"epdg.epc.mnc001.mcc460.pub.3gppnetwork.org",
			"epdg.epc.mnc000.mcc460.pub.3gppnetwork.org",
		}))
	})

	It("restarts the modem explicitly after an IMS setting change", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())

		Expect(controller.RestartModem(context.Background())).To(Succeed())

		Expect(commander.commands).To(Equal([]string{"AT+CFUN=1,1"}))
	})

	It("reports a modem restart failure to the caller", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		commander.err = errors.New("serial disconnected")

		Expect(controller.RestartModem(context.Background())).To(MatchError(ContainSubstring("serial disconnected")))
		Expect(commander.commands).To(Equal([]string{"AT+CFUN=1,1"}))
	})

	It("keeps the previous VoLTE preference when IMS is unsupported", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		commander.response = at.Response{Terminal: "+CME ERROR: 4"}
		enabled := true

		settings, err := controller.Configure(context.Background(), Update{VoLTEEnabled: &enabled})

		Expect(err).To(MatchError(`modem rejected slot policy command AT+QCFG="ims",1: +CME ERROR: 4`))
		Expect(settings.VoLTEEnabled).To(BeFalse())
		Expect(controller.Current().VoLTEEnabled).To(BeFalse())
	})

	It("does not apply the data preference when leaving airplane mode", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		enabled, disabled := true, false
		_, err = controller.Configure(context.Background(), Update{AirplaneModeEnabled: &enabled})
		Expect(err).NotTo(HaveOccurred())
		_, err = controller.Configure(context.Background(), Update{DataEnabled: &disabled})
		Expect(err).NotTo(HaveOccurred())
		_, err = controller.Configure(context.Background(), Update{AirplaneModeEnabled: &disabled})
		Expect(err).NotTo(HaveOccurred())
		Expect(commander.commands).To(Equal([]string{"AT+CFUN=0", "AT+CFUN=1"}))
	})

	It("restores airplane state without detaching packet service", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		disabled := false
		_, err = controller.Configure(context.Background(), Update{DataEnabled: &disabled})
		Expect(err).NotTo(HaveOccurred())
		commander.commands = nil
		Expect(controller.Restore(context.Background())).To(Succeed())
		Expect(commander.commands).To(Equal([]string{"AT+CFUN=1"}))
	})

	It("persists the data preference without sending a modem command", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		commander.err = errors.New("serial unavailable")
		disabled := false
		settings, err := controller.Configure(context.Background(), Update{DataEnabled: &disabled})
		Expect(err).NotTo(HaveOccurred())
		Expect(settings.DataEnabled).To(BeFalse())
		Expect(commander.commands).To(BeEmpty())
		reloaded, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		Expect(reloaded.Current()).To(Equal(settings))
	})

	It("does not rewrite state or touch the modem for an unchanged policy", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		enabled := true

		settings, err := controller.Configure(context.Background(), Update{
			DataEnabled:          &enabled,
			IncomingCallsEnabled: &enabled,
			IncomingSMSEnabled:   &enabled,
		})

		Expect(err).NotTo(HaveOccurred())
		Expect(settings).To(Equal(controller.Current()))
		Expect(commander.commands).To(BeEmpty())
		_, statError := os.Stat(filepath.Join(directory, "slot-policy.json"))
		Expect(statError).To(MatchError(os.ErrNotExist))
	})

	It("surfaces an airplane mode rejection without changing the saved policy", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		commander.response = at.Response{Terminal: "ERROR"}
		enabled := true

		settings, err := controller.Configure(context.Background(), Update{AirplaneModeEnabled: &enabled})

		Expect(err).To(MatchError("modem rejected slot policy command AT+CFUN=0: ERROR"))
		Expect(settings.AirplaneModeEnabled).To(BeFalse())
		Expect(controller.Current().AirplaneModeEnabled).To(BeFalse())
	})

	It("persists data preference changes while airplane mode keeps the radio disabled", func() {
		controller, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		enabled, disabled := true, false
		_, err = controller.Configure(context.Background(), Update{AirplaneModeEnabled: &enabled})
		Expect(err).NotTo(HaveOccurred())
		commander.commands = nil

		settings, err := controller.Configure(context.Background(), Update{DataEnabled: &disabled})

		Expect(err).NotTo(HaveOccurred())
		Expect(settings.DataEnabled).To(BeFalse())
		Expect(commander.commands).To(BeEmpty())
		reloaded, err := NewController(directory, commander, time.Second)
		Expect(err).NotTo(HaveOccurred())
		Expect(reloaded.Current()).To(Equal(settings))
	})

	It("validates constructor dependencies and stored state", func() {
		_, err := NewController("relative", commander, time.Second)
		Expect(err).To(HaveOccurred())
		_, err = NewController(directory, nil, time.Second)
		Expect(err).To(HaveOccurred())
		Expect(os.WriteFile(filepath.Join(directory, "slot-policy.json"), []byte(`{"version":99}`), 0o600)).To(Succeed())
		_, err = NewController(directory, commander, time.Second)
		Expect(err).To(MatchError("persisted slot policy is invalid"))

		filePath := filepath.Join(GinkgoT().TempDir(), "not-a-directory")
		Expect(os.WriteFile(filePath, []byte("occupied"), 0o600)).To(Succeed())
		_, err = NewController(filePath, commander, time.Second)
		Expect(err).To(MatchError(ContainSubstring("create slot policy directory")))
	})
})
