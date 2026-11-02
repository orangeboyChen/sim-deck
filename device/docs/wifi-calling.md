# Wi-Fi Calling state and device diagnostics

The outer SIM settings apply to the active SIM or eSIM profile. Mobile Data,
Airplane Mode, incoming calls, incoming SMS, VoLTE, and Wi-Fi Calling preferences
are stored by eSIM profile ID (ICCID). Inactive profile preferences can be edited
without changing the modem. Switching profiles restores their settings and
invalidates the old IMS registration and SIP call. Removing a physical SIM
clears the former eSIM policy from the active slot while retaining per-profile
preferences locally.

Wi-Fi Calling appears as an enabled switch only when the device has the local
SIP and IMS companion configuration described in
[`deployment.md`](deployment.md#optional-wi-fi-calling-companion). Enabling it
stores a preference; it does not claim carrier support. The device routes an
outgoing call through Wi-Fi only when its local SIP account is registered and
the companion reports one carrier line with all of these healthy:

- carrier IMS registration;
- ePDG transport with a P-CSCF assignment;
- a usable IPsec CHILD_SA;
- the IMS Gm signaling connection.

If any condition is missing, outgoing calls use the modem's cellular voice
path. “Check Again” asks the device to scrape the companion's local metrics.
`ims_registered` means the four carrier conditions above were observed for the
same line; it is not proof of a successful call or audio on that carrier.
`ims_transport_unavailable` means IMS may be registered but its IPsec or Gm
path is not currently usable. `ims_reconnecting` means a changed eSIM profile
has not yet shown a fresh registration. `backend_unavailable` means the
companion could not be queried.

Without an IMS companion, “Check Again” performs a limited diagnostic. The
device reads the active SIM's IMSI over its serialized AT connection, derives
standard ePDG names for both possible MNC lengths, and resolves them using
the host network. The IMSI is neither persisted nor returned to the app.
`gateway_found` means a standard hostname resolved. `gateway_not_found` means
neither resolved; carriers can use other names. Neither result establishes
entitlement or IMS registration, and the device does not route calls over
Wi-Fi in this mode.

`SIM_DECK_VOWIFI_AT_BRIDGE=true` can also expose a private Unix AT socket at
`<state-directory>/ims-at.sock` to a trusted companion. This is a transport
for serialized modem commands, not an IMS implementation. The provided
Compose deployment uses two independent AT ports on one modem instead.

The local SIP, metrics, and Compose checks require no provisioned SIM. Real
carrier registration, inbound and outbound calls, and two-way audio still
require a provisioned SIM or eSIM on the target modem.
