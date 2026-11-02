# Wi-Fi Calling state and device diagnostics

The `wifi_calling_enabled` control records the owner's preference on the modem
host. For an eSIM, preferences for Mobile Data, Airplane Mode, incoming calls,
incoming SMS, VoLTE, and Wi-Fi Calling are keyed by the modem's profile ID
(ICCID). The outer SIM settings operate on the currently enabled eSIM profile.
Preferences for an inactive profile can be saved without changing the modem;
the device applies its radio and VoLTE settings when that profile becomes active.

Turning on Wi-Fi Calling performs a device-side diagnostic. The device reads the
active SIM's IMSI through its serialized AT connection, derives possible 2- and
3-digit MNC ePDG names, and resolves their standard DNS names over the host's
network. The IMSI is not persisted or returned to the app. A manual refresh
repeats the diagnostic.

| Status | Meaning |
| --- | --- |
| `off` | The owner preference is off. |
| `inactive_profile` | This eSIM profile is not active, so it cannot be probed. |
| `not_checked` | The profile became active and needs a fresh probe. |
| `gateway_found` | At least one standard ePDG hostname resolved. |
| `gateway_not_found` | Neither standard hostname resolved. |
| `probe_failed` | The IMSI or DNS probe failed. |

**No status confirms carrier entitlement or IMS registration.** A carrier may
use a different ePDG name, and DNS resolution alone cannot establish that the
SIM is authorized. The current device call path still uses modem cellular
voice. Native calls over the host's Wi-Fi require an ePDG IKEv2/EAP-AKA client,
IMS SIP registration, protected media, and integration with the existing call
and WebRTC controllers. Until that path is implemented and tested with a real
modem and carrier, the app must not label the preference as an active VoWiFi
connection or route calls through it.
