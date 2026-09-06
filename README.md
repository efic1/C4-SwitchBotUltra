# SwitchBot Lock Ultra — Control4 Driver

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Version:** 1.1.0 · driver.xml `<version>` 114

---

## Contents

- [Overview](#overview)
- [Features](#features)
- [Setup](#setup)
- [Properties](#properties)
- [Actions](#actions)
- [Programming](#programming)
- [Lock states explained](#lock-states-explained)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)
- [Building from source](#building-from-source)
- [Status](#status)

---

## Overview

Two-way integration between the **SwitchBot Lock Ultra** and Control4, via the
SwitchBot Open Cloud API v1.1. The driver locks and unlocks the deadbolt, reports
lock state, door state and battery level, and exposes events for Composer
programming.

Like most cloud locks in Control4, this driver is the *backend*. The device the
end user sees in Navigator is Control4's generic **Door Lock** driver, bound to
this one. This is the same architecture Yale's own Control4 driver uses.

---

## Features

- Lock, Unlock and Toggle
- Real-time lock state: locked, unlocked, fault, and partial (latch / half-lock)
- Door open/closed state via a Door Contact sensor
- Battery level reporting, with a low-battery event below 15%
- Automatic device discovery from the SwitchBot account
- Configurable polling (30 / 60 / 300 seconds)
- Programming events: Lock Jammed, Calibration Error, Door Opened, Door Closed,
  Door Left Open, Low Battery, Communication Failure, Communication Restored

---

## Setup

### Requirements

- Control4 OS 3.3.0 or later
- **SwitchBot Hub** (Hub Mini, Hub 2 or later) paired to the lock, with **Cloud
  Services enabled** on the lock
- A SwitchBot **OpenToken** and **Secret Key**
- Controller with outbound HTTPS access to `api.switch-bot.com`
- The lock must be controllable from the SwitchBot app before integrating

### Hardware installation

1. Install and calibrate the Lock Ultra using the SwitchBot app.
2. Confirm the lock responds from the app while away from the local network. If
   the app cannot reach it remotely, the driver cannot either.

### Obtain the API credentials

1. In the SwitchBot app: **Profile → Preferences → About**
2. Tap **App Version** ten times to reveal **Developer Options**
3. Copy the **Token** and the **Secret Key**

### Driver installation

1. In Composer Pro, **System Design → Search**, add **SwitchBot Lock Ultra** to
   the room.
2. On the **Properties** tab, paste **OpenToken** and **SecretKey**.
3. **Actions → Test Connection.** The Lua output should report success and the
   device count. Resolve any authentication error before continuing.
4. **Actions → Discover Devices**, then pick the lock in **Device Selection**.
   Entries appear as `Friendly Name (deviceId)`.
5. Set **Poll Frequency** (see [rate limits](#will-this-hit-switchbots-api-limits)).
6. Add **My Drivers → Motorization → Door Lock** to the same room. This is the
   device that appears in Navigator.
7. Add a **Door Contact** sensor to the room for door state in the UI.

### Connections

On the **Connections** tab:

| This driver's binding | Connect to |
| --- | --- |
| **Lock Control** (Relay) | The **Door Lock** driver's **Relay** binding |
| **Door State** (Contact) | The **Door Contact** sensor |

**Lock State** (Contact) is also provided, if you want lock state to appear as a
separate contact sensor alongside the Door Lock tile.

Refresh Navigators when finished.

---

## Properties

| Property | Description |
| --- | --- |
| Driver Version | Read-only. Confirms which build is running. |
| OpenToken | SwitchBot developer token. |
| SecretKey | SwitchBot secret key, used to sign every request. |
| Device Selection | Populated by **Discover Devices**. Shown as `Name (deviceId)`. |
| Partial Lock Reports As | How a latch-bolt or half-lock position is reported. Default **Unlocked**. See [Lock states](#lock-states-explained). |
| Poll Frequency | 30, 60 or 300 seconds. Default 60. |
| Lock Contact Polarity | `Closed = Locked` (default) or inverted. |
| Door Contact Polarity | `Closed = Door Shut` (default) or inverted. |
| Debug Mode | Off / Basic / Verbose. Errors always print regardless. |
| Lock Status | Read-only. `locked`, `unlocked`, `fault` or `unknown`. |
| Lock Detail | Read-only. The raw underlying state, including partial and stale conditions. |
| Door Status | Read-only. `open` or `closed`. |
| Battery Level | Read-only percentage. |
| Last Sync | Read-only timestamp of the last successful poll. |
| Connection Status | Read-only. Connected / Not configured / Authentication failed / Error. |

---

## Actions

| Action | Description |
| --- | --- |
| Discover Devices | Queries the SwitchBot account and populates **Device Selection**. |
| Refresh Status | Forces an immediate poll. |
| Test Connection | Verifies credentials and reports the device count. |
| Log Raw Status | Prints the exact SwitchBot API response next to what the driver concluded, regardless of Debug Mode. The fastest way to diagnose a state disagreement. |
| Resend Contact State | Re-publishes contact state without restarting Director. |
| Send Deadbolt Command | Sends SwitchBot's `deadbolt` command. See the [FAQ](#what-does-send-deadbolt-command-do). |

---

## Programming

| Event | Fires when |
| --- | --- |
| Lock Jammed | The motor reports jammed or blocked. |
| Calibration Error | The lock reports it is not calibrated. |
| Door Opened / Door Closed | Door state changes. |
| Door Left Open | The door has been open for five minutes. |
| Low Battery | Battery drops below 15%. Fires once per crossing. |
| Communication Failure | Repeated failures reaching the SwitchBot cloud. |
| Communication Restored | Communication recovers. |

**Do not treat the Door Lock tile as proof the door is secured.** A relay is an
output, so that tile reflects what Control4 commanded, not what the bolt did. For
conditional logic that depends on the door genuinely being locked — a "Goodnight"
scene, an away check — use this driver's **Lock Status** property or the **Lock
State** contact. Both come from polled device telemetry.

---

## Lock states explained

The Lock Ultra reports more states than Control4's lock proxy has, so the driver
maps them:

| SwitchBot state | Reported to Control4 | Notes |
| --- | --- | --- |
| `lock` | locked | Deadbolt thrown. |
| `unlock` | unlocked | |
| `latchBoltLocked`, `halfLocked`, `notFullyLocked` | per **Partial Lock Reports As** | Deadbolt **not** fully thrown. |
| `jammed`, `lockingStop`, `unlockingStop` | fault | Also fires Lock Jammed. |
| `locking`, `unlocking` | *unchanged* | Motor mid-travel; holds the previous state and re-checks. |
| anything unrecognised | unknown | Logs the full API payload. |

### Partial states and the door-open rule

`latchBoltLocked` and `halfLocked` mean the door is held but the **deadbolt is not
fully thrown**. Whether that counts as locked depends on the door hardware, so it
is a setting — defaulting to **Unlocked**, because reporting a partially secured
door as Locked asserts security that does not exist.

**One rule cannot be configured:** if the door is **open**, a partial state is
never reported as locked. Opening a door lets the latch bolt spring out, which
makes the lock report `latchBoltLocked`; an open door must never read as Locked.

---

## FAQ

### Why is a second driver needed?

Cloud lock drivers in Control4, including Yale's own, act as a backend and bind to
the generic **Door Lock** driver, which is what Navigator renders. The relay
binding carries commands; the contact bindings carry state.

### Why not webhooks?

SwitchBot pushes events to a **publicly reachable HTTPS URL**. A Control4
controller sits behind NAT without a publicly trusted certificate, so it cannot
receive that callback without port forwarding plus a valid certificate, a reverse
proxy, or a cloud relay. Rather than ship a feature that silently does nothing,
the driver polls.

### Will this hit SwitchBot's API limits?

SwitchBot allows roughly **10,000 calls per day per account**, shared across every
application using that account. One lock at 30-second polling uses about 2,880
calls per day; at 60 seconds, about 1,440. Check the arithmetic before deploying
several locks on one account.

### What does Send Deadbolt Command do?

SwitchBot documents a third command, `deadbolt`, described only as "disengage
deadbolt or latch". That description is ambiguous and users have reported
inconsistent behaviour, so it is exposed as an explicit action rather than wired
into Lock/Unlock. Test it on the bench before using it in programming.

### Does this support user codes or lock history?

No. The driver declares `has_settings`, `has_custom_settings`,
`has_internal_history` and `max_users` as unsupported. Lock, unlock and telemetry
only.

---

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Wrong version shown | The load banner names the running build: `SwitchBot Lock Ultra driver v1.1.0 loaded`. If absent, the update did not land — restart Composer Pro, then **Update Driver**. |
| Lock Status stays `unknown` | Set Debug Mode to **Basic**. An unrecognised state logs the full API payload. |
| Lock Detail says `STALE` | No successful poll for three intervals. Check **Connection Status** and **Last Sync**. |
| Device Selection empty | Run **Test Connection**, then **Discover Devices**. |
| Driver state disagrees with the lock | Run **Log Raw Status** and compare against the SwitchBot app. If Lock Detail says `Partial:`, see [Lock states](#lock-states-explained). |
| Lock or door state inverted | Flip **Lock Contact Polarity** or **Door Contact Polarity**. |
| Contact bound but never updates | Run **Resend Contact State**. Contacts report on change only, so a binding made mid-session receives nothing until the next transition. |
| Authentication failures | Requests are timestamp-signed. Confirm the controller clock is correct. |
| Nothing appears in Navigator | Confirm the **Door Lock** driver is in the room and its Relay is bound, then refresh Navigators. |

---

## Building from source

```bash
sudo apt-get install -y lua5.4 zip
lua5.4 tests/test_json.lua      #  39 tests - JSON encode/decode
lua5.4 tests/test_driver.lua    # 190 tests - driver logic against a mocked C4 API
./package.sh                    # -> build/SwitchBotLockUltra.c4z
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the repository layout, the safety
rules the driver must preserve, and the packaging constraints Composer depends
on.

Tests cover state mapping for every documented SwitchBot state, the door-open
safety rule, jam and calibration handling, failed-command rollback, battery
thresholds, contact de-duplication and polarity, back-off, staleness, discovery,
the proxy handshake, and credential redaction in logs. Request signing is
cross-checked against Python's `hmac`/`hashlib`.



---

See [CHANGELOG.md](CHANGELOG.md) for release history.
