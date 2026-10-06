# Change log

All notable changes to this driver. Versions map to `driver.xml` `<version>`,
which Control4 uses to detect updates.

**1.2.0** — Reliability release.
- Lock/unlock commands, the reads that verify them, and manual Composer actions
  are no longer suppressed by back-off. Only background polling is.
- A failed command now reliably re-reads the real lock state.
- A command is tracked for 15 seconds after the cloud accepts it. Cloud
  telemetry that lags the motor is no longer logged as a failure, and a
  command that never confirms expires instead of mislabelling later keypad
  changes as Control4 actions. Verification reads stop once confirmed.
- The first reading after boot, a device change, or stale recovery is an
  initial sync: reported as not manual, and without Door Opened / Door Closed
  events. A door found open still raises Door Left Open.
- Lock Jammed and Calibration Error fire once when the fault begins, not on
  every poll while it persists.
- A lock stuck reporting `locking` / `unlocking` is re-checked at most six
  times, then reported unknown, instead of being polled every two seconds
  indefinitely.
- Startup request burst removed: property changes replayed at load are ignored
  until initialisation completes, credential changes are debounced, and
  re-selecting the same lock (including after a rename) does nothing.
- Changing the selected lock now resets all per-device state and notifies the
  proxy.
- New test suite (50 tests) against a mocked controller.

**1.1.0** — Documentation rewritten as an installation and usage guide. Battery
status no longer re-sent on every poll. Removed a dead state field and a stale
comment.

**1.0.13** — Low battery no longer warns above 15%; the proxy status had been
warning from 50% down, disagreeing with the event threshold. Full
request/response, state-transition and per-poll logging, with `Authorization` and
`sign` headers redacted.

**1.0.12** — A partial lock state with the door open is never reported as locked.
`Partial Lock Reports As` now defaults to Unlocked.

**1.0.11** — Staleness guard: stops asserting a lock state after three failed
polling intervals. Added **Log Raw Status**.

**1.0.10** — Contact state re-published when a binding is connected, plus
**Resend Contact State**.

**1.0.9** — Contacts report on change only, with correct state-versus-transition
semantics and configurable polarity.

**1.0.8** — Added Relay and Contact bindings so the generic **Door Lock** driver
can be bound.

**1.0.7** — Packaging and XML conformance: no XML declaration, no directory
entries in the `.c4z`, production element order.

**1.0.6** — `Locks` category, hidden proxy connection, eleven additional
capabilities, documentation file.

**1.0.5** — `LOCK_STATUS_INITIALIZE` proxy handshake, full `<capabilities>` block,
`fault` as a lock state.

**1.0.4** — Full proxy handshake logging.

**1.0.3** — Version reporting made authoritative across all load paths.

**1.0.2** — Complete lock state vocabulary; `LUA_ACTION` dispatch fixed; device
discovery re-runs after a driver update.

**1.0.1** — Corrected state vocabulary to SwitchBot's documented values.

**1.0.0** — Initial build.
