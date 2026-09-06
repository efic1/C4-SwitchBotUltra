# Contributing

## Repository layout

```
src/                 Everything that ships inside the .c4z
  driver.xml         Driver definition: properties, proxy, bindings, capabilities
  driver.lua         Driver logic
  sbjson.lua         Self-contained JSON encode/decode
  www/               Dealer documentation shown in Composer
tests/               Test suites (run off-controller against a mocked C4 API)
package.sh           Builds build/SwitchBotLockUltra.c4z
```

## Running the tests

```bash
sudo apt-get install -y lua5.4 zip
lua5.4 tests/test_json.lua      # JSON encode/decode
lua5.4 tests/test_driver.lua    # driver logic
./package.sh                    # build the .c4z
```

Both suites run from the repository root and exit non-zero on failure. CI runs
them on every push and pull request.

`tests/mock_sha256.lua` is a test fixture only — a pure-Lua SHA-256 backing the
mocked `C4:Hash` so request signing can be exercised off-controller. The driver
itself uses the controller's native `C4:Hash`.

## What the tests can and cannot tell you

The harness is a **model** of the DriverWorks API, not the API. A green suite
means the state machine, signing and safety rules behave correctly against that
model. It says nothing about whether Director will load the driver, whether a
proxy notification is spelled right, or whether Navigator will render anything.
Anything touching the proxy handshake, bindings or packaging still needs testing
on a real controller.

## Things that will silently break the driver

These were each found the hard way. Please keep them intact.

**Packaging.** Control4's packager produces an archive with no directory entries,
and `driver.xml` must have **no XML declaration**. Get either wrong and Composer's
"Update Driver" fails silently, forcing a remove-and-re-add on every change.
`package.sh` enforces both; CI verifies them.

**Version bumps.** Update all three together:

- `DRIVER_VERSION` in `src/driver.lua`
- the Driver Version property `<default>` in `src/driver.xml`
- `<version>` in `src/driver.xml` (integer, must increase)

CI fails if the first two disagree. Keep `<name>`, `<model>`, `<manufacturer>`,
`<creator>` and the `.c4z` filename stable — changing any of them makes Composer
treat the driver as new rather than an update.

**Actions.** An `<action>` arrives at `ExecuteCommand` as `LUA_ACTION` with the
action's **`<name>`** in `tParams.ACTION`. The `<command>` element is not used for
dispatch. Handler keys are the uppercased name with spaces as underscores, so
`Refresh Status` maps to `EX.REFRESH_STATUS`.

**Proxy states.** The lock proxy accepts exactly `unknown`, `locked`, `unlocked`
and `fault`. `LOCK_STATUS_INITIALIZE` must be sent once before any
`LOCK_STATUS_CHANGED`, or Navigator never treats the lock as present.

**Contacts.** `STATE_CLOSED` / `STATE_OPENED` report state; `CLOSED` / `OPENED`
signal a transition. Send state on first report and transitions only on change —
re-sending on every poll floods programming with phantom events.

## Safety rules — do not relax these

This driver controls a door lock. A tile that reads "Locked" on an unsecured door
is the worst thing it can do, so ambiguity always resolves toward *not locked*.

- A jam, blocked motor or uncalibrated lock reports `fault`, never `locked`.
- **A partial state (`latchBoltLocked`, `halfLocked`) with the door open is never
  reported as locked.** This is not configurable. Opening a door lets the latch
  bolt spring out, which makes the lock report `latchBoltLocked`.
- `Partial Lock Reports As` defaults to **Unlocked**. A partial state means the
  deadbolt is not fully thrown.
- Commands are never trusted on the cloud's acknowledgement; actual device state
  is re-read before the UI is updated.
- `TOGGLE` from an unknown or fault state refuses to actuate.
- If no successful poll happens for three intervals, the driver reports `unknown`
  rather than continuing to assert a stale state.

## Logging

Credentials must never reach the log. `Authorization` and `sign` headers are
redacted; bodies are logged in full, headers are not. There is a test that fails
if the token or secret key ever appears in printed output — keep it passing.

## Adding a new SwitchBot state

State strings are normalised to lowercase alphanumerics before lookup, so
`halfLocked`, `half_locked` and `HALF_LOCKED` all collapse to one entry. Add the
new key to `LOCK_STATE_MAP` with one of: `secure`, `open`, `partial`, `fault`,
`transitional`. Unrecognised states log the full API payload, so a report from the
field should contain everything needed to map it.

## Reference material

Do not commit other vendors' drivers or documentation. The Yale Home driver used
during development to compare `driver.xml` structure is proprietary to Chowmain /
ASSA ABLOY; no code from it is in this project, and `.gitignore` excludes it.
