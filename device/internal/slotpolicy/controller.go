package slotpolicy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"sim-deck-device/internal/at"
)

const stateVersion = 2

// Settings is the effective owner policy for one physical modem slot.
type Settings struct {
	DataEnabled          bool   `json:"data_enabled"`
	AirplaneModeEnabled  bool   `json:"airplane_mode_enabled"`
	IncomingCallsEnabled bool   `json:"incoming_calls_enabled"`
	IncomingSMSEnabled   bool   `json:"incoming_sms_enabled"`
	VoLTEEnabled         bool   `json:"volte_enabled"`
	WiFiCallingEnabled   bool   `json:"wifi_calling_enabled"`
	WiFiCallingStatus    string `json:"wifi_calling_status,omitempty"`
}

// Update contains optional policy changes from an authenticated encrypted command.
type Update struct {
	DataEnabled          *bool
	AirplaneModeEnabled  *bool
	IncomingCallsEnabled *bool
	IncomingSMSEnabled   *bool
	VoLTEEnabled         *bool
	WiFiCallingEnabled   *bool
}

// Commander is the serialized AT command capability required by the policy controller.
type Commander interface {
	Send(context.Context, string) (at.Response, error)
}

// Controller persists slot policy and applies its radio-related settings to the modem.
type Controller struct {
	mu              sync.RWMutex
	path            string
	commander       Commander
	timeout         time.Duration
	settings        Settings
	profiles        map[string]Settings
	activeProfileID string
	lookupIP        func(context.Context, string) ([]net.IPAddr, error)
}

type persistedSettings struct {
	Version int `json:"version"`
	Settings
	Profiles        map[string]Settings `json:"profiles,omitempty"`
	ActiveProfileID string              `json:"active_profile_id,omitempty"`
}

// NewController opens the durable policy for one modem container.
func NewController(directory string, commander Commander, timeout time.Duration) (*Controller, error) {
	if directory == "" || !filepath.IsAbs(directory) || commander == nil || timeout <= 0 {
		return nil, errors.New("slot policy requires an absolute state directory, modem commander, and positive timeout")
	}
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return nil, fmt.Errorf("create slot policy directory: %w", err)
	}
	path := filepath.Join(directory, "slot-policy.json")
	state, err := load(path)
	if err != nil {
		return nil, err
	}
	if state.Profiles == nil {
		state.Profiles = make(map[string]Settings)
	}
	// Earlier builds stored the requested switch state without an IMS backend.
	// Clear it so callers never mistake that preference for a working service.
	changed := state.Settings.WiFiCallingEnabled
	state.Settings.WiFiCallingEnabled = false
	for profileID, settings := range state.Profiles {
		if settings.WiFiCallingEnabled {
			changed = true
			settings.WiFiCallingEnabled = false
			state.Profiles[profileID] = settings
		}
	}
	if changed {
		if err := save(path, state); err != nil {
			return nil, fmt.Errorf("clear unavailable Wi-Fi Calling preference: %w", err)
		}
	}
	return &Controller{path: path, commander: commander, timeout: timeout, settings: state.Settings,
		profiles: state.Profiles, activeProfileID: state.ActiveProfileID, lookupIP: net.DefaultResolver.LookupIPAddr}, nil
}

// Current returns a consistent snapshot of the persisted owner policy.
func (controller *Controller) Current() Settings {
	controller.mu.RLock()
	defer controller.mu.RUnlock()
	return controller.settings
}

// Profile returns stored preferences without applying an inactive profile to the modem.
func (controller *Controller) Profile(profileID string) Settings {
	controller.mu.RLock()
	defer controller.mu.RUnlock()
	if settings, ok := controller.profiles[profileID]; ok {
		return settings
	}
	return defaultSettings()
}

// SelectProfile follows the eUICC's enabled profile and restores its preferences.
func (controller *Controller) SelectProfile(ctx context.Context, profileID string) error {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	if profileID == controller.activeProfileID {
		return nil
	}
	previous := controller.settings
	next := defaultSettings()
	if saved, ok := controller.profiles[profileID]; profileID != "" && ok {
		next = saved
	} else if len(controller.profiles) == 0 && controller.activeProfileID == "" {
		// Migrate the former slot-wide preferences to the first active profile.
		next = previous
	}
	if profileID != "" && next.WiFiCallingStatus != "" {
		next.WiFiCallingStatus = "not_checked"
	}
	if err := controller.applyTransition(ctx, previous, next); err != nil {
		return err
	}
	profiles := cloneProfiles(controller.profiles)
	if _, exists := profiles[controller.activeProfileID]; controller.activeProfileID != "" && controller.activeProfileID != profileID && exists {
		inactive := previous
		if inactive.WiFiCallingStatus != "" {
			inactive.WiFiCallingStatus = "inactive_profile"
		}
		profiles[controller.activeProfileID] = inactive
	}
	if profileID != "" {
		profiles[profileID] = next
	}
	if err := save(controller.path, persistedSettings{Version: stateVersion, Settings: next, Profiles: profiles, ActiveProfileID: profileID}); err != nil {
		return err
	}
	controller.settings, controller.profiles, controller.activeProfileID = next, profiles, profileID
	return nil
}

// ForgetProfile removes preferences for a profile deleted from the eUICC.
func (controller *Controller) ForgetProfile(profileID string) error {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	profiles := cloneProfiles(controller.profiles)
	delete(profiles, profileID)
	if err := save(controller.path, persistedSettings{Version: stateVersion, Settings: controller.settings, Profiles: profiles, ActiveProfileID: controller.activeProfileID}); err != nil {
		return err
	}
	controller.profiles = profiles
	return nil
}

// Restore reapplies the persisted airplane policy after modem initialization.
func (controller *Controller) Restore(ctx context.Context) error {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	return controller.applyRadio(ctx, controller.settings, true)
}

// Configure applies a partial update and returns the resulting effective policy.
func (controller *Controller) Configure(ctx context.Context, update Update) (Settings, error) {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	return controller.configure(ctx, controller.activeProfileID, update)
}

// ConfigureProfile stores an installed eSIM's preferences independently.
func (controller *Controller) ConfigureProfile(ctx context.Context, profileID string, update Update) (Settings, error) {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	if profileID == "" {
		return Settings{}, errors.New("eSIM profile ID is required")
	}
	return controller.configure(ctx, profileID, update)
}

func (controller *Controller) configure(ctx context.Context, profileID string, update Update) (Settings, error) {
	active := profileID == controller.activeProfileID
	previous := controller.settings
	if !active {
		previous = controller.profileLocked(profileID)
	}
	next := previous
	if update.DataEnabled != nil {
		// The device does not open a SIM data session. Detaching packet service
		// here would also disconnect IMS and break VoLTE calls.
		next.DataEnabled = *update.DataEnabled
	}
	if update.AirplaneModeEnabled != nil {
		next.AirplaneModeEnabled = *update.AirplaneModeEnabled
	}
	if update.IncomingCallsEnabled != nil {
		next.IncomingCallsEnabled = *update.IncomingCallsEnabled
	}
	if update.IncomingSMSEnabled != nil {
		next.IncomingSMSEnabled = *update.IncomingSMSEnabled
	}
	if update.VoLTEEnabled != nil {
		next.VoLTEEnabled = *update.VoLTEEnabled
	}
	if update.WiFiCallingEnabled != nil {
		if *update.WiFiCallingEnabled {
			return previous, errors.New("Wi-Fi Calling requires a device IMS backend")
		}
		next.WiFiCallingEnabled = false
	}
	if !active && next.WiFiCallingStatus != "" {
		next.WiFiCallingStatus = "inactive_profile"
	}
	if active {
		if err := controller.applyTransition(ctx, previous, next); err != nil {
			return previous, err
		}
	}
	if next == previous {
		return next, nil
	}
	profiles := cloneProfiles(controller.profiles)
	if profileID != "" {
		profiles[profileID] = next
	}
	current := controller.settings
	if active {
		current = next
	}
	if err := save(controller.path, persistedSettings{Version: stateVersion, Settings: current, Profiles: profiles, ActiveProfileID: controller.activeProfileID}); err != nil {
		return previous, err
	}
	controller.settings, controller.profiles = current, profiles
	return next, nil
}

// ProbeWiFiCalling refreshes gateway discovery for the active SIM only.
// A gateway DNS result is not carrier entitlement or IMS registration.
func (controller *Controller) ProbeWiFiCalling(ctx context.Context, profileID string) (Settings, error) {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	if profileID != controller.activeProfileID {
		return controller.profileLocked(profileID), errors.New("eSIM profile is not active")
	}
	next := controller.settings
	next.WiFiCallingStatus = controller.probeWiFiCalling(ctx)
	if next == controller.settings {
		return next, nil
	}
	profiles := cloneProfiles(controller.profiles)
	if profileID != "" {
		profiles[profileID] = next
	}
	if err := save(controller.path, persistedSettings{Version: stateVersion, Settings: next, Profiles: profiles, ActiveProfileID: controller.activeProfileID}); err != nil {
		return controller.settings, err
	}
	controller.settings, controller.profiles = next, profiles
	return next, nil
}

func (controller *Controller) profileLocked(profileID string) Settings {
	if settings, ok := controller.profiles[profileID]; ok {
		return settings
	}
	return defaultSettings()
}

func cloneProfiles(source map[string]Settings) map[string]Settings {
	result := make(map[string]Settings, len(source))
	for id, settings := range source {
		result[id] = settings
	}
	return result
}

func (controller *Controller) applyTransition(ctx context.Context, previous, next Settings) error {
	if previous.VoLTEEnabled != next.VoLTEEnabled {
		if err := controller.applyVoLTE(ctx, next.VoLTEEnabled); err != nil {
			return err
		}
	}
	return controller.applyRadio(ctx, next, previous.AirplaneModeEnabled != next.AirplaneModeEnabled)
}

func (controller *Controller) probeWiFiCalling(ctx context.Context) string {
	probeContext, cancel := context.WithTimeout(ctx, controller.timeout)
	defer cancel()
	response, err := controller.commander.Send(probeContext, "AT+CIMI")
	if err != nil || !response.OK() {
		return "probe_failed"
	}
	var imsi string
	for _, line := range response.Lines {
		candidate := strings.TrimSpace(line)
		if len(candidate) >= 6 && len(candidate) <= 15 && allDigits(candidate) {
			imsi = candidate
			break
		}
	}
	if imsi == "" {
		return "probe_failed"
	}
	// MNC length is not reliably encoded in the IMSI. Query both candidates
	// and report discovery only, never carrier authorization.
	lookupFailed := false
	for _, width := range []int{3, 2} {
		mnc := imsi[3 : 3+width]
		if width == 2 {
			mnc = "0" + mnc
		}
		name := fmt.Sprintf("epdg.epc.mnc%s.mcc%s.pub.3gppnetwork.org", mnc, imsi[:3])
		addresses, err := controller.lookupIP(probeContext, name)
		if err == nil && len(addresses) != 0 {
			return "gateway_found"
		}
		if err != nil {
			var dnsError *net.DNSError
			if !errors.As(err, &dnsError) || !dnsError.IsNotFound {
				lookupFailed = true
			}
		}
	}
	if probeContext.Err() != nil || lookupFailed {
		return "probe_failed"
	}
	return "gateway_not_found"
}

func allDigits(value string) bool {
	for _, char := range value {
		if char < '0' || char > '9' {
			return false
		}
	}
	return true
}

// RestartModem performs the full modem reset required after changing IMS configuration.
func (controller *Controller) RestartModem(ctx context.Context) error {
	controller.mu.Lock()
	defer controller.mu.Unlock()
	return controller.send(ctx, "AT+CFUN=1,1")
}

func (controller *Controller) applyVoLTE(ctx context.Context, enabled bool) error {
	value := "0"
	if enabled {
		value = "1"
	}
	return controller.send(ctx, `AT+QCFG="ims",`+value)
}

func (controller *Controller) applyRadio(ctx context.Context, settings Settings, airplaneChanged bool) error {
	if settings.AirplaneModeEnabled {
		if airplaneChanged {
			return controller.send(ctx, "AT+CFUN=0")
		}
		return nil
	}
	if airplaneChanged {
		return controller.send(ctx, "AT+CFUN=1")
	}
	return nil
}

func (controller *Controller) send(ctx context.Context, command string) error {
	commandContext, cancel := context.WithTimeout(ctx, controller.timeout)
	defer cancel()
	response, err := controller.commander.Send(commandContext, command)
	if err != nil {
		return fmt.Errorf("apply slot policy command %s: %w", command, err)
	}
	if !response.OK() {
		return fmt.Errorf("modem rejected slot policy command %s: %s", command, response.Terminal)
	}
	return nil
}

func defaultSettings() Settings {
	return Settings{DataEnabled: true, IncomingCallsEnabled: true, IncomingSMSEnabled: true}
}

func load(path string) (persistedSettings, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return persistedSettings{Version: stateVersion, Settings: defaultSettings()}, nil
	}
	if err != nil {
		return persistedSettings{}, fmt.Errorf("read slot policy: %w", err)
	}
	var persisted persistedSettings
	if err := json.Unmarshal(data, &persisted); err != nil || (persisted.Version != 1 && persisted.Version != stateVersion) {
		return persistedSettings{}, errors.New("persisted slot policy is invalid")
	}
	return persisted, nil
}

func save(path string, settings persistedSettings) error {
	data, err := json.Marshal(settings)
	if err != nil {
		return fmt.Errorf("encode slot policy: %w", err)
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".slot-policy-*")
	if err != nil {
		return fmt.Errorf("create slot policy temporary file: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("secure slot policy temporary file: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("write slot policy: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("sync slot policy: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close slot policy: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("replace slot policy: %w", err)
	}
	return nil
}
