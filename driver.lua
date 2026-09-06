--[[============================================================================
	SwitchBot Lock Ultra - Control4 DriverWorks driver
	Version 1.1.0

	Transport : SwitchBot Open Cloud API v1.1 over HTTPS (device must be paired
	            to a SwitchBot Hub with cloud services enabled)
	Proxy     : lock (proxy binding 5001)
	Sync      : background polling. Webhook push is deliberately not implemented;
	            see "Why not webhooks?" in the documentation.

	API notes (these are the real DriverWorks signatures, verified against
	Control4's own drivers-common-public libraries):
	  C4:url()                       -> transfer object; :OnDone(fn):Get(url, headers)
	                                    OnDone(transfer, responses, errCode, errMsg)
	                                    responses[#responses].body / .code / .headers
	  C4:SetTimer(delayMs, fn, rpt)  -> timer object; cancel with timer:Cancel()
	  C4:Hash('SHA256', data, opts)  -> native hash, raw bytes with NONE encodings
	  C4:Base64Encode(str)
	  C4:GetTime()                   -> wall clock milliseconds
	  C4:SendToProxy(5001, 'LOCK_STATUS_CHANGED', {LOCK_STATUS=...}, 'NOTIFY')
	  C4:SendToProxy(5001, 'BATTERY_STATUS_CHANGED', {BATTERY_STATUS=...}, 'NOTIFY')
==============================================================================]]

JSON = require ('sbjson')

do	-- Constants
	DRIVER_VERSION      = '1.1.0'

	API_BASE            = 'https://api.switch-bot.com'
	PATH_DEVICES        = '/v1.1/devices'

	LOCK_BINDING        = 5001

	-- Contact/relay bindings, so a generic Door Lock (My Drivers > Motorization)
	-- driver can be bound to this one. Yale's shipping driver requires exactly
	-- this pairing: its install guide instructs the dealer to add the Door Lock
	-- driver and connect it, because the manufacturer driver alone does not
	-- present a lock in Navigator.
	RELAY_BINDING       = 300	-- RELAY:          CLOSE -> lock, OPEN -> unlock
	LOCK_STATE_BINDING  = 400	-- CONTACT_SENSOR: closed = locked
	DOOR_STATE_BINDING  = 401	-- CONTACT_SENSOR: closed = door shut

	-- PRD 3.2: low battery below 15%. The proxy's 'warning' status is what
	-- Navigator renders as a low-battery indication, so it must not trip above
	-- that threshold - previously it did, at anything up to 50%.
	LOW_BATTERY_PCT      = 15		-- below this: warning (and Low Battery event)
	CRITICAL_BATTERY_PCT = 5		-- below this: critical
	DOOR_LEFT_OPEN_MS   = 5 * 60 * 1000
	CONFIRM_DELAY_MS    = 2000		-- re-poll after a command to confirm real state
	REQUEST_TIMEOUT_MS  = 10000
	LATENCY_BUDGET_MS   = 2500		-- PRD 4

	BACKOFF_BASE_MS     = 5000
	BACKOFF_MAX_MS      = 300000

	-- Raw-in / raw-out so C4:Hash returns binary we can feed straight back in.
	HASH_RAW = {
		return_encoding = 'NONE',
		data_encoding   = 'NONE',
	}

	POLL_SECONDS = {
		['30 seconds']  = 30,
		['60 seconds']  = 60,
		['300 seconds'] = 300,
	}

	-- SwitchBot deviceType strings that identify a lock. UNVERIFIED for the
	-- Ultra specifically - see README. Discovery falls back to a substring
	-- match on 'Lock' so a new model name still shows up in the dropdown.
	LOCK_DEVICE_TYPES = {
		['Smart Lock']       = true,
		['Smart Lock Pro']   = true,
		['Smart Lock Ultra'] = true,
		['Lock Ultra']       = true,
	}
end

do	-- Driver state
	RFP = RFP or {}					-- ReceivedFromProxy dispatch
	EX  = EX  or {}					-- ExecuteCommand dispatch
	Timers = Timers or {}

	State = State or {
		lockState        = 'unknown',	-- locked | unlocked | unknown
		doorState        = 'unknown',	-- open | closed | unknown
		batteryPct       = nil,
		batteryStatus    = nil,
		lowBatteryFired  = false,
		doorLeftOpenFired = false,

		failures         = 0,
		backoffUntil     = 0,
		commFailureFired = false,

		pendingCommand   = nil,
		inFlight         = false,
		initialized      = false,
		contact          = {},
		lastGoodSync     = nil,
		stale            = false,
	}
end

-- ============================================================================
-- Logging
-- ============================================================================

local function DbgBasic (msg)
	local mode = Properties ['Debug Mode']
	if (mode == 'Basic' or mode == 'Verbose') then
		print ('[SwitchBot] ' .. tostring (msg))
	end
end

local function DbgVerbose (msg)
	if (Properties ['Debug Mode'] == 'Verbose') then
		print ('[SwitchBot:v] ' .. tostring (msg))
	end
end

-- Headers carry the OpenToken and the request signature. They must never reach
-- the Lua window or a support log, so they are redacted before printing.
local function RedactHeaders (headers)
	local safe = {}
	for k, v in pairs (headers or {}) do
		local lk = string.lower (k)
		if (lk == 'authorization' or lk == 'sign') then
			safe [#safe + 1] = k .. '=<redacted>'
		else
			safe [#safe + 1] = k .. '=' .. tostring (v)
		end
	end
	table.sort (safe)
	return table.concat (safe, ', ')
end

local function Truncate (s, limit)
	s = tostring (s or '')
	limit = limit or 800
	if (#s <= limit) then return s end
	return string.sub (s, 1, limit) .. '... [' .. #s .. ' bytes total]'
end

local function LogError (msg)
	-- Always printed. A dealer diagnosing a lock in the field should not have
	-- to know to turn debug on first.
	print ('[SwitchBot:ERROR] ' .. tostring (msg))
	C4:ErrorLog ('SwitchBot Lock Ultra: ' .. tostring (msg))
end

-- ============================================================================
-- Timer helpers (C4:SetTimer returns an object; cancel via timer:Cancel())
-- ============================================================================

local function CancelTimer (name)
	local t = Timers [name]
	if (t ~= nil) then
		if (type (t) == 'userdata' and t.Cancel) then
			t:Cancel ()
		end
		Timers [name] = nil
	end
end

local function StartTimer (name, delayMs, fn, repeating)
	CancelTimer (name)
	Timers [name] = C4:SetTimer (delayMs, function (timer, skips)
		if (repeating ~= true) then
			Timers [name] = nil
		end
		local ok, err = pcall (fn)
		if (not ok) then
			LogError ('timer "' .. name .. '" error: ' .. tostring (err))
		end
	end, (repeating == true))
end

local function Now ()
	if (C4.GetTime) then
		return C4:GetTime ()
	end
	return os.time () * 1000
end

-- ============================================================================
-- SwitchBot request signing
--
-- SwitchBot v1.1 requires:
--   Authorization: <token>
--   t:     epoch milliseconds
--   nonce: arbitrary unique string
--   sign:  base64( HMAC-SHA256( secret, token .. t .. nonce ) ), uppercased
--
-- HMAC is built on top of the controller's native C4:Hash rather than a
-- pure-Lua SHA-256, so the hashing runs in C instead of on the Lua thread.
-- ============================================================================

local function ByteXor (a, b)
	local result, bit = 0, 1
	for _ = 1, 8 do
		local abit, bbit = a % 2, b % 2
		if (abit ~= bbit) then result = result + bit end
		a = (a - abit) / 2
		b = (b - bbit) / 2
		bit = bit * 2
	end
	return result
end

local function Sha256Raw (data)
	return C4:Hash ('SHA256', data, HASH_RAW)
end

local function HmacSha256Raw (key, message)
	local blockSize = 64

	if (#key > blockSize) then
		key = Sha256Raw (key)
	end
	key = key .. string.rep ('\0', blockSize - #key)

	local oPad, iPad = {}, {}
	for i = 1, blockSize do
		local kb = string.byte (key, i)
		oPad [i] = string.char (ByteXor (kb, 0x5C))
		iPad [i] = string.char (ByteXor (kb, 0x36))
	end

	return Sha256Raw (table.concat (oPad) .. Sha256Raw (table.concat (iPad) .. message))
end

local function BuildHeaders ()
	local token  = Properties ['OpenToken'] or ''
	local secret = Properties ['SecretKey'] or ''

	local t     = tostring (math.floor (Now ()))
	local nonce = tostring (math.random (100000000, 999999999))
	local sign  = string.upper (C4:Base64Encode (HmacSha256Raw (secret, token .. t .. nonce)))

	return {
		['Authorization'] = token,
		['sign']          = sign,
		['t']             = t,
		['nonce']         = nonce,
		['Content-Type']  = 'application/json; charset=utf8',
	}
end

-- ============================================================================
-- Reliability: back-off + comm state
-- ============================================================================

local function InBackoff ()
	return Now () < (State.backoffUntil or 0)
end

local function EnterBackoff ()
	State.failures = (State.failures or 0) + 1

	local delay = BACKOFF_BASE_MS * (2 ^ (State.failures - 1))
	if (delay > BACKOFF_MAX_MS) then delay = BACKOFF_MAX_MS end
	State.backoffUntil = Now () + delay

	DbgBasic ('backing off ' .. math.floor (delay / 1000) .. 's (failure #' .. State.failures .. ')')
	C4:UpdateProperty ('Connection Status', 'Error - retrying')

	if (not State.commFailureFired) then
		State.commFailureFired = true
		C4:FireEvent ('Communication Failure')
	end
end

local function ClearBackoff ()
	State.failures = 0
	State.backoffUntil = 0
	C4:UpdateProperty ('Connection Status', 'Connected')

	if (State.commFailureFired) then
		State.commFailureFired = false
		C4:FireEvent ('Communication Restored')
	end
end

-- ============================================================================
-- HTTP
-- callback (ok, body, httpCode)
-- ============================================================================

local function ApiRequest (method, path, bodyTable, callback)
	local token  = Properties ['OpenToken'] or ''
	local secret = Properties ['SecretKey'] or ''

	if (token == '' or secret == '') then
		DbgBasic ('request skipped: credentials not set')
		if (callback) then callback (false, nil, nil) end
		return
	end

	if (InBackoff ()) then
		DbgVerbose ('request suppressed, in back-off: ' .. path)
		if (callback) then callback (false, nil, nil) end
		return
	end

	local url     = API_BASE .. path
	local headers = BuildHeaders ()
	local data    = (bodyTable ~= nil) and JSON:encode (bodyTable) or ''
	local started = Now ()

	DbgVerbose ('--> ' .. method .. ' ' .. url)
	DbgVerbose ('    headers: ' .. RedactHeaders (headers))
	if (data ~= '') then
		DbgVerbose ('    body:    ' .. data)
	end

	local transfer = C4:url ()

	transfer:SetOptions ({
		timeout        = REQUEST_TIMEOUT_MS,
		fail_on_error  = false,
		cookies_enable = false,
	})

	transfer:OnDone (function (t, responses, errCode, errMsg)
		local elapsed = Now () - started

		local response = responses and responses [#responses]
		DbgVerbose (string.format ('<-- HTTP %s  %dms  %s',
			tostring (response and response.code or 'n/a'), elapsed, path))
		if (response and response.body) then
			DbgVerbose ('    body: ' .. Truncate (response.body))
		end
		if (errCode ~= 0) then
			DbgVerbose ('    errCode=' .. tostring (errCode) .. ' errMsg=' .. tostring (errMsg))
		end

		if (elapsed > LATENCY_BUDGET_MS) then
			DbgBasic ('slow response (' .. elapsed .. 'ms, budget ' .. LATENCY_BUDGET_MS .. 'ms): ' .. path)
		end

		if (errCode ~= 0) then
			LogError ('transport error on ' .. path .. ': ' .. tostring (errMsg))
			EnterBackoff ()
			if (callback) then callback (false, nil, nil) end
			return
		end

		local code = response and response.code
		local body = response and response.body

		if (code == 429) then
			LogError ('rate limited (HTTP 429) on ' .. path)
			EnterBackoff ()
			if (callback) then callback (false, nil, 429) end
			return
		end

		if (code == nil or code >= 400) then
			LogError ('HTTP ' .. tostring (code) .. ' on ' .. path)
			EnterBackoff ()
			if (callback) then callback (false, nil, code) end
			return
		end

		local decoded = JSON:decode (body)
		if (decoded == nil) then
			LogError ('could not decode response from ' .. path)
			EnterBackoff ()
			if (callback) then callback (false, nil, code) end
			return
		end

		-- SwitchBot returns app-level failures inside an HTTP 200.
		if (decoded.statusCode ~= nil and decoded.statusCode ~= 100) then
			LogError ('SwitchBot API error ' .. tostring (decoded.statusCode) ..
				' on ' .. path .. ': ' .. tostring (decoded.message))
			EnterBackoff ()
			if (callback) then callback (false, decoded, code) end
			return
		end

		ClearBackoff ()
		if (callback) then callback (true, decoded, code) end
	end)

	if (method == 'POST') then
		transfer:Post (url, data, headers)
	else
		transfer:Get (url, headers)
	end
end

-- ============================================================================
-- Proxy state push
-- ============================================================================

-- The lock proxy accepts exactly four states (LockDevice.IsValidState in
-- Control4's lock_proxy template): unknown, locked, unlocked, fault.
-- A jam is 'fault', never 'locked'.
local VALID_PROXY_STATES = { unknown = true, locked = true, unlocked = true, fault = true }

local function NotifyLockState (newState, source, manual, description)
	if (not VALID_PROXY_STATES [newState]) then
		LogError ('refusing to send invalid proxy state "' .. tostring (newState) .. '"')
		return
	end

	if (not State.initialized) then
		-- The proxy needs LOCK_STATUS_INITIALIZE before it treats the device as
		-- present. Without it the lock is never offered in Navigator at all.
		C4:SendToProxy (LOCK_BINDING, 'LOCK_STATUS_INITIALIZE',
			{ LOCK_STATUS = newState }, 'NOTIFY')
		State.initialized = true
		DbgBasic (string.format ('lock state: %s -> %s  (initial report to proxy)',
			tostring (State.lockState), tostring (newState)))
		State.lockState = newState
		return
	end

	if (newState == State.lockState) then return end

	DbgBasic (string.format ('lock state: %s -> %s  (source=%s, manual=%s)%s',
		tostring (State.lockState), tostring (newState), tostring (source or 'SwitchBot'),
		tostring (manual == true),
		(description and description ~= '') and ('  [' .. description .. ']') or ''))

	C4:SendToProxy (LOCK_BINDING, 'LOCK_STATUS_CHANGED', {
		LOCK_STATUS              = newState,
		LAST_ACTION_DESCRIPTION  = description or '',
		SOURCE                   = source or 'SwitchBot',
		MANUAL                   = (manual == true),
	}, 'NOTIFY')

	State.lockState = newState
end

-- Mirror state onto the contact bindings. Command and notification names are
-- the documented Contact/Relay set (OPENED / CLOSED / STATE_OPENED /
-- STATE_CLOSED, and CLOSE / OPEN / TOGGLE / TRIGGER).
-- Contact semantics: STATE_CLOSED / STATE_OPENED report the current state
-- without signalling a transition; CLOSED / OPENED signal an actual change and
-- drive programming. v1.0.8 sent both on every poll, which re-announced a
-- transition every polling interval even when nothing had changed.
local function NotifyContact (binding, closed)
	local previous = State.contact [binding]

	if (previous == nil) then
		-- First report: set state only, so adding the driver does not look
		-- like the door just opened or the lock just turned.
		C4:SendToProxy (binding, closed and 'STATE_CLOSED' or 'STATE_OPENED', {}, 'NOTIFY')
	elseif (previous ~= closed) then
		C4:SendToProxy (binding, closed and 'CLOSED' or 'OPENED', {}, 'NOTIFY')
	else
		return		-- unchanged: say nothing
	end

	DbgVerbose ('contact ' .. tostring (binding) .. ': ' ..
		(closed and 'CLOSED' or 'OPENED') ..
		((previous == nil) and ' (initial state report)' or ' (transition)'))

	State.contact [binding] = closed
end

-- Which contact polarity the paired Door Lock driver expects is not something
-- I can determine from here, so it is a dealer setting rather than a guess.
local function MirrorLockStateToContact (newState)
	local closed
	if (newState == 'locked') then
		closed = true
	elseif (newState == 'unlocked') then
		closed = false
	else
		return		-- fault/unknown: hold the last reported contact state
	end

	if (Properties ['Lock Contact Polarity'] == 'Closed = Unlocked') then
		closed = not closed
	end

	NotifyContact (LOCK_STATE_BINDING, closed)
end

local function NotifyBattery (pct)
	pct = tonumber (pct)
	if (pct == nil) then return end

	local status
	if (pct >= LOW_BATTERY_PCT) then
		status = 'normal'
	elseif (pct >= CRITICAL_BATTERY_PCT) then
		status = 'warning'
	else
		status = 'critical'
	end

	-- Only notify the proxy when the status band actually changes; re-sending
	-- an unchanged battery status on every poll is noise.
	if (status ~= State.batteryStatus) then
		DbgBasic (string.format ('battery: %s%% -> %s (was %s)', tostring (pct), status,
			tostring (State.batteryStatus or 'unknown')))
		C4:SendToProxy (LOCK_BINDING, 'BATTERY_STATUS_CHANGED', { BATTERY_STATUS = status }, 'NOTIFY')
		State.batteryStatus = status
	elseif (pct ~= State.batteryPct) then
		DbgVerbose ('battery: ' .. tostring (pct) .. '% (' .. status .. ')')
	end

	C4:UpdateProperty ('Battery Level', tostring (pct) .. '%')

	if (pct < LOW_BATTERY_PCT) then
		if (not State.lowBatteryFired) then
			State.lowBatteryFired = true
			C4:FireEvent ('Low Battery')
		end
	else
		State.lowBatteryFired = false
	end

	State.batteryPct = pct
end

local function UpdateDoorState (newState)
	if (newState == State.doorState) then return end

	DbgBasic ('door state: ' .. tostring (State.doorState) .. ' -> ' .. tostring (newState))
	State.doorState = newState
	C4:UpdateProperty ('Door Status', newState)

	local doorClosed = (newState == 'closed')
	if (Properties ['Door Contact Polarity'] == 'Closed = Door Open') then
		doorClosed = not doorClosed
	end
	NotifyContact (DOOR_STATE_BINDING, doorClosed)

	if (newState == 'open') then
		C4:FireEvent ('Door Opened')
		State.doorLeftOpenFired = false
		StartTimer ('doorLeftOpen', DOOR_LEFT_OPEN_MS, function ()
			if (State.doorState == 'open' and not State.doorLeftOpenFired) then
				State.doorLeftOpenFired = true
				C4:FireEvent ('Door Left Open')
			end
		end, false)

	elseif (newState == 'closed') then
		C4:FireEvent ('Door Closed')
		State.doorLeftOpenFired = false
		CancelTimer ('doorLeftOpen')
	end
end

-- SwitchBot spells these inconsistently across models, regions and firmware
-- (latchBoltLocked, LATCH_LOCKED, halfLocked, LOCKING_STOP...). Normalising to
-- lowercase alphanumerics collapses every spelling of the same state, so a new
-- separator or capitalisation cannot break the mapping again.
local function NormalizeState (s)
	return (string.gsub (string.lower (tostring (s or '')), '[^a-z0-9]', ''))
end

-- Full lock status enum, per SwitchBot's Lock Ultra API docs and the reference
-- pySwitchbot LockStatus enum (LOCKED, UNLOCKED, LOCKING, UNLOCKING,
-- LOCKING_STOP, UNLOCKING_STOP, NOT_FULLY_LOCKED/LATCH_LOCKED, HALF_LOCKED).
--   'secure'      -> report locked
--   'open'        -> report unlocked
--   'partial'     -> deadbolt not fully thrown; dealer decides (see property)
--   'fault'       -> motor blocked/jammed; report unknown + fire event
--   'transitional'-> motor still moving; hold last state and re-poll
local LOCK_STATE_MAP = {
	lock             = 'secure',
	locked           = 'secure',

	unlock           = 'open',
	unlocked         = 'open',

	latchboltlocked  = 'partial',	-- EU latch engaged, deadbolt not thrown
	latchlocked      = 'partial',
	notfullylocked   = 'partial',
	halflocked       = 'partial',	-- Lock Ultra EU half-lock position
	partiallocked    = 'partial',
	partiallylocked  = 'partial',

	jammed           = 'fault',
	lockingstop      = 'fault',		-- LOCKING_BLOCKED
	unlockingstop    = 'fault',		-- UNLOCKING_BLOCKED
	lockingblocked   = 'fault',
	unlockingblocked = 'fault',

	locking          = 'transitional',
	unlocking        = 'transitional',
}

local function ApplyStatus (status)
	if (type (status) ~= 'table') then return end

	local raw = NormalizeState (status.lockState)
	local kind = LOCK_STATE_MAP [raw]
	local mapped

	if (status.calibrate == false) then
		mapped = 'fault'
		C4:UpdateProperty ('Lock Detail', 'Not calibrated')
		C4:FireEvent ('Calibration Error')

	elseif (kind == 'secure') then
		mapped = 'locked'
		C4:UpdateProperty ('Lock Detail', 'Locked (deadbolt thrown)')

	elseif (kind == 'open') then
		mapped = 'unlocked'
		C4:UpdateProperty ('Lock Detail', 'Unlocked')

	elseif (kind == 'partial') then
		-- Latch or half-lock position: the deadbolt is NOT fully thrown.
		--
		-- Hard safety rule, not configurable: if the door is open, a partial
		-- state can never be reported as locked. An open door with the latch
		-- bolt sprung out is exactly this case, and calling it "Locked" is the
		-- worst error this driver can make.
		local doorIsOpen = (State.doorState == 'open')
		local rawDoor = status.doorState and tostring (status.doorState):lower () or nil
		if (rawDoor == 'open' or rawDoor == 'opened') then doorIsOpen = true end

		if (doorIsOpen) then
			mapped = 'unlocked'
			C4:UpdateProperty ('Lock Detail', 'Partial: ' .. tostring (status.lockState) ..
				' with door OPEN - reporting unlocked')
			DbgBasic ('partial lock state with door open - forcing unlocked')

		elseif (Properties ['Partial Lock Reports As'] == 'Locked') then
			mapped = 'locked'
			C4:UpdateProperty ('Lock Detail', 'Partial: ' .. tostring (status.lockState) ..
				' (deadbolt NOT fully thrown, reported as locked by setting)')

		else
			mapped = 'unlocked'
			C4:UpdateProperty ('Lock Detail', 'Partial: ' .. tostring (status.lockState) ..
				' (deadbolt not fully thrown)')
		end

	elseif (kind == 'fault') then
		mapped = 'fault'
		C4:UpdateProperty ('Lock Detail', 'Fault: ' .. tostring (status.lockState))
		C4:FireEvent ('Lock Jammed')

	elseif (kind == 'transitional') then
		-- Motor is still moving. Do not publish a state mid-travel; hold the
		-- last known one and look again shortly.
		DbgBasic ('lock is mid-travel (' .. tostring (status.lockState) .. '), re-checking')
		C4:UpdateProperty ('Lock Detail', 'Moving: ' .. tostring (status.lockState))
		StartTimer ('transitional', CONFIRM_DELAY_MS, RefreshStatus, false)
		mapped = nil

	elseif (status.lockState == nil) then
		-- Field absent entirely (partial payload / wrong endpoint). Not the
		-- same as an unrecognised value, and not worth an error each poll.
		mapped = 'unknown'
		C4:UpdateProperty ('Lock Detail', 'No lockState in response')
		DbgBasic ('status response contained no lockState field')

	else
		mapped = 'unknown'
		C4:UpdateProperty ('Lock Detail', 'Unrecognised: ' .. tostring (status.lockState))
		LogError ('unrecognised lockState "' .. tostring (status.lockState) ..
			'". Full status payload follows so this can be mapped without another round trip:')
		LogError (JSON:encode (status) or '<could not encode>')
	end

	-- Publish the lock state, unless the motor is mid-travel (mapped == nil),
	-- in which case the last known state is held until the re-poll lands.
	if (mapped ~= nil) then
		-- If we did not issue the change ourselves, it happened at the door -
		-- keypad, fingerprint, thumbturn - so report it as a manual action.
		local ours = (State.pendingCommand ~= nil)
		NotifyLockState (mapped,
			ours and 'Control4' or 'SwitchBot',
			not ours,
			ours and 'Control4 command' or 'Changed at the lock')
		C4:UpdateProperty ('Lock Status', mapped)
		MirrorLockStateToContact (mapped)
	end

	-- Door contact. SwitchBot has used both a doorState string and a boolean
	-- across models, so accept either shape rather than guessing one.
	local door = status.doorState
	if (door ~= nil) then
		door = tostring (door):lower ()
		if (door == 'opened' or door == 'open' or door == 'true') then
			UpdateDoorState ('open')
		elseif (door == 'closed' or door == 'close' or door == 'false') then
			UpdateDoorState ('closed')
		end
	elseif (type (status.doorOpen) == 'boolean') then
		UpdateDoorState (status.doorOpen and 'open' or 'closed')
	end

	if (status.battery ~= nil) then
		NotifyBattery (status.battery)
	end

	-- Reconcile any optimistic command.
	if (State.pendingCommand ~= nil and mapped ~= nil) then
		if (State.pendingCommand == mapped) then
			DbgBasic ('command confirmed: ' .. mapped)
		else
			LogError ('command "' .. State.pendingCommand ..
				'" did not take effect - device reports "' .. mapped .. '"')
		end
		State.pendingCommand = nil
	end

	DbgBasic (string.format (
		'poll: raw lockState=%s  doorState=%s  battery=%s  calibrated=%s  -> reported %s',
		tostring (status.lockState), tostring (status.doorState),
		tostring (status.battery), tostring (status.calibrate),
		tostring (mapped or State.lockState)))

	State.lastGoodSync = Now ()
	if (State.stale) then
		State.stale = false
		DbgBasic ('fresh data received; leaving stale state')
	end
	C4:UpdateProperty ('Last Sync', os.date ('%Y-%m-%d %H:%M:%S'))
end

-- Called on each poll tick. If nothing has been read successfully for several
-- intervals, stop reporting the last known state and say 'unknown' instead.
local function CheckStaleness ()
	local seconds = POLL_SECONDS [Properties ['Poll Frequency']] or 60
	local limit = seconds * 3 * 1000

	if (State.lastGoodSync == nil) then return end
	if ((Now () - State.lastGoodSync) < limit) then return end
	if (State.stale) then return end

	State.stale = true
	LogError ('no successful status read for over ' .. math.floor (limit / 1000) ..
		's - reporting lock state as unknown rather than a stale value')
	C4:UpdateProperty ('Lock Detail', 'STALE - no recent update from SwitchBot')
	C4:UpdateProperty ('Lock Status', 'unknown')
	NotifyLockState ('unknown', 'SwitchBot', false, 'No recent update')
end

-- ============================================================================
-- Actions against the API
-- ============================================================================

local function GetDeviceId ()
	local sel = Properties ['Device Selection'] or ''
	if (sel == '' or sel == 'Select a device...') then
		return nil
	end
	-- Entries are stored as "Friendly Name (deviceId)".
	return string.match (sel, '%((.-)%)$') or sel
end

function RefreshStatus ()
	local deviceId = GetDeviceId ()
	if (deviceId == nil) then
		DbgBasic ('refresh skipped: no device selected')
		return
	end

	ApiRequest ('GET', PATH_DEVICES .. '/' .. deviceId .. '/status', nil, function (ok, decoded)
		if (ok and decoded and decoded.body) then
			ApplyStatus (decoded.body)
		else
			C4:UpdateProperty ('Last Sync', os.date ('%Y-%m-%d %H:%M:%S') .. ' (failed)')
		end
	end)
end

local function SendLockCommand (command)
	local deviceId = GetDeviceId ()
	if (deviceId == nil) then
		LogError ('cannot send "' .. command .. '": no device selected')
		return
	end

	if (State.inFlight) then
		DbgBasic ('ignoring "' .. command .. '": a command is already in flight')
		return
	end

	State.inFlight = true
	State.pendingCommand = (command == 'lock') and 'locked' or 'unlocked'

	ApiRequest ('POST', PATH_DEVICES .. '/' .. deviceId .. '/commands', {
		command     = command,
		parameter   = 'default',
		commandType = 'command',
	}, function (ok)
		State.inFlight = false

		-- The cloud acking a command is not evidence the bolt moved. Always
		-- re-read real device state before trusting the UI.
		if (ok) then
			DbgBasic ('command "' .. command .. '" accepted; confirming actual state')
			StartTimer ('confirm', CONFIRM_DELAY_MS, RefreshStatus, false)
			-- Second look: an EU multipoint lock can still be travelling at
			-- the first check, which would read as a spurious failure.
			StartTimer ('confirm2', CONFIRM_DELAY_MS * 3, RefreshStatus, false)
		else
			LogError ('command "' .. command .. '" failed; re-reading device state')
			State.pendingCommand = nil
			RefreshStatus ()
		end
	end)
end

function DiscoverDevices ()
	ApiRequest ('GET', PATH_DEVICES, nil, function (ok, decoded)
		if (not ok or not decoded or not decoded.body) then
			LogError ('device discovery failed')
			return
		end

		local list = decoded.body.deviceList or {}
		local found = {}

		for _, dev in ipairs (list) do
			local dType = tostring (dev.deviceType or '')
			if (LOCK_DEVICE_TYPES [dType] or string.find (dType, 'Lock')) then
				table.insert (found, tostring (dev.deviceName) .. ' (' .. tostring (dev.deviceId) .. ')')
			end
		end

		if (#found == 0) then
			LogError ('no lock devices found on this SwitchBot account')
			C4:UpdateProperty ('Connection Status', 'Connected - no locks found')
			return
		end

		DbgBasic ('discovered ' .. #found .. ' lock device(s)')

		-- Preserve the dealer's existing choice. A driver update wipes the
		-- runtime list back to the XML default, so this runs on every init -
		-- it must never silently repoint the driver at a different lock.
		local current = Properties ['Device Selection']
		local keep = nil
		for _, entry in ipairs (found) do
			if (entry == current) then keep = entry break end
		end

		C4:UpdatePropertyList ('Device Selection', table.concat (found, ','), keep or found [1])
	end)
end

-- ============================================================================
-- Polling
-- ============================================================================

function StartPolling ()
	CancelTimer ('poll')

	local seconds = POLL_SECONDS [Properties ['Poll Frequency']] or 60
	DbgBasic ('polling every ' .. seconds .. 's')

	StartTimer ('poll', seconds * 1000, function ()
		CheckStaleness ()
		RefreshStatus ()
	end, true)
end

-- ============================================================================
-- Proxy commands (lock proxy -> driver)
-- ============================================================================

function RFP.LOCK (idBinding, strCommand, tParams)
	DbgBasic ('proxy: LOCK')
	SendLockCommand ('lock')
end

function RFP.UNLOCK (idBinding, strCommand, tParams)
	DbgBasic ('proxy: UNLOCK')
	SendLockCommand ('unlock')
end

function RFP.TOGGLE (idBinding, strCommand, tParams)
	DbgBasic ('proxy: TOGGLE (current state: ' .. tostring (State.lockState) .. ')')

	if (State.lockState == 'locked') then
		SendLockCommand ('unlock')
	elseif (State.lockState == 'unlocked') then
		SendLockCommand ('lock')
	else
		-- Never guess which way to move a deadbolt from an unknown state.
		LogError ('TOGGLE ignored: lock state is unknown. Refreshing status instead.')
		RefreshStatus ()
	end
end

-- The proxy asks for these during initialisation. Answering keeps the tile
-- from sitting in a pending state; this driver exposes no user codes or
-- device settings, so the replies are deliberately minimal.
function RFP.REQUEST_CAPABILITIES (idBinding, strCommand, tParams)
	DbgVerbose ('proxy: REQUEST_CAPABILITIES')
end

-- has_settings and has_custom_settings are declared false in driver.xml, so
-- there is nothing legitimate to return here. The real SETTINGS notification
-- carries an XML document, not a table; replying with an empty table would be
-- malformed. Acknowledge in the log and send nothing.
function RFP.REQUEST_SETTINGS (idBinding, strCommand, tParams)
	DbgVerbose ('proxy: REQUEST_SETTINGS (no settings exposed)')
end

function RFP.REQUEST_CUSTOM_SETTINGS (idBinding, strCommand, tParams)
	DbgVerbose ('proxy: REQUEST_CUSTOM_SETTINGS (none exposed)')
end

function RFP.REQUEST_USERS (idBinding, strCommand, tParams)
	DbgVerbose ('proxy: REQUEST_USERS')
end

function RFP.REQUEST_HISTORY (idBinding, strCommand, tParams)
	DbgVerbose ('proxy: REQUEST_HISTORY')
end

local function DumpParams (tParams)
	local parts = {}
	for k, v in pairs (tParams or {}) do
		parts [#parts + 1] = tostring (k) .. '=' .. tostring (v)
	end
	if (#parts == 0) then return '(no params)' end
	return table.concat (parts, ', ')
end

local function HandleRelayCommand (strCommand)
	if (strCommand == 'CLOSE') then
		DbgBasic ('relay CLOSE -> lock')
		SendLockCommand ('lock')
	elseif (strCommand == 'OPEN') then
		DbgBasic ('relay OPEN -> unlock')
		SendLockCommand ('unlock')
	elseif (strCommand == 'TOGGLE' or strCommand == 'TRIGGER') then
		if (State.lockState == 'locked') then
			SendLockCommand ('unlock')
		elseif (State.lockState == 'unlocked') then
			SendLockCommand ('lock')
		else
			LogError ('relay ' .. strCommand .. ' ignored: lock state unknown')
			RefreshStatus ()
		end
	else
		DbgVerbose ('unhandled relay command: ' .. tostring (strCommand))
	end
end

function ReceivedFromProxy (idBinding, strCommand, tParams)
	tParams = tParams or {}

	-- Full visibility of the proxy handshake, so an unexpected request or an
	-- unexpected parameter shows up in the log instead of being silent.
	DbgVerbose ('proxy <- binding ' .. tostring (idBinding) .. ' : ' ..
		tostring (strCommand) .. ' : ' .. DumpParams (tParams))

	if (idBinding == RELAY_BINDING) then
		local ok, err = pcall (HandleRelayCommand, strCommand)
		if (not ok) then
			LogError ('relay command ' .. tostring (strCommand) .. ': ' .. tostring (err))
		end
		return
	end

	if (RFP [strCommand] ~= nil) then
		local ok, err = pcall (RFP [strCommand], idBinding, strCommand, tParams)
		if (not ok) then
			LogError ('ReceivedFromProxy ' .. tostring (strCommand) .. ': ' .. tostring (err))
		end
	else
		DbgBasic ('UNHANDLED proxy command: ' .. tostring (strCommand) ..
			' : ' .. DumpParams (tParams))
	end
end

-- ============================================================================
-- Composer actions / commands
-- ============================================================================

function EX.DISCOVER_DEVICES () DiscoverDevices () end
function EX.REFRESH_STATUS ()   RefreshStatus ()   end

-- SwitchBot documents a third command, "deadbolt", described only as
-- "disengage deadbolt or latch". That description is ambiguous and users have
-- reported inconsistent behaviour, so it is exposed as an explicit action
-- rather than wired into LOCK/UNLOCK. Test it on the bench before using it in
-- programming.
function EX.SEND_DEADBOLT_COMMAND ()
	SendLockCommand ('deadbolt')
end

-- Prints exactly what the SwitchBot cloud reports, regardless of Debug Mode, so
-- the API's view can be compared directly against the SwitchBot app and the
-- physical lock. This is the fastest way to tell a mapping problem from stale
-- cloud data.
function EX.LOG_RAW_STATUS ()
	local deviceId = GetDeviceId ()
	if (deviceId == nil) then
		print ('[SwitchBot] No device selected.')
		return
	end

	ApiRequest ('GET', PATH_DEVICES .. '/' .. deviceId .. '/status', nil, function (ok, decoded)
		if (ok and decoded) then
			print ('[SwitchBot] RAW STATUS: ' .. (JSON:encode (decoded) or '?'))
			print ('[SwitchBot] Driver reports: lockState=' .. tostring (State.lockState) ..
				'  doorState=' .. tostring (State.doorState) ..
				'  stale=' .. tostring (State.stale))
		else
			print ('[SwitchBot] RAW STATUS request failed.')
		end
	end)
end

function EX.RESEND_CONTACT_STATE ()
	ResendContactState ()
end

function EX.TEST_CONNECTION ()
	ApiRequest ('GET', PATH_DEVICES, nil, function (ok, decoded)
		if (ok and decoded and decoded.body) then
			local n = #(decoded.body.deviceList or {})
			print ('[SwitchBot] Connection OK. ' .. n .. ' device(s) on account.')
			C4:UpdateProperty ('Connection Status', 'Connected')
		else
			print ('[SwitchBot] Connection FAILED. Check OpenToken and SecretKey.')
			C4:UpdateProperty ('Connection Status', 'Authentication failed')
		end
	end)
end

function ExecuteCommand (strCommand, tParams)
	tParams = tParams or {}

	-- Actions from Composer's Actions tab arrive as LUA_ACTION with the
	-- action's <name> in tParams.ACTION - not as the <command> element.
	if (strCommand == 'LUA_ACTION' and tParams.ACTION ~= nil) then
		DbgVerbose ('action: ' .. tostring (tParams.ACTION))
		strCommand = tParams.ACTION
	end

	local key = string.gsub (tostring (strCommand), '%s+', '_')
	key = string.upper (key)

	if (EX [key] ~= nil) then
		local ok, err = pcall (EX [key], tParams)
		if (not ok) then
			LogError ('ExecuteCommand ' .. tostring (strCommand) .. ': ' .. tostring (err))
		end
	else
		DbgVerbose ('unhandled command: ' .. tostring (strCommand))
	end
end

-- ============================================================================
-- Driver lifecycle
-- ============================================================================

local function ReportVersion (context)
	-- Deliberately not gated behind Debug Mode. If the driver is running at
	-- all, the log must state which build it is - a stale Driver Version
	-- property was previously the only signal, and it lied.
	print ('[SwitchBot] SwitchBot Lock Ultra driver v' .. DRIVER_VERSION ..
		' loaded (' .. context .. ')')
	C4:UpdateProperty ('Driver Version', DRIVER_VERSION)
end

function OnDriverInit ()
	C4:AllowExecute (true)
	math.randomseed (Now ())
	-- OnDriverInit runs on every load path, including driver updates where
	-- OnDriverLateInit may not be re-run and persisted property values survive.
	ReportVersion ('OnDriverInit')
end

function OnDriverLateInit ()
	DbgBasic ('OnDriverLateInit')

	ReportVersion ('OnDriverLateInit')

	-- Start from unknown rather than assuming a state we have not read.
	NotifyLockState ('unknown')

	local token  = Properties ['OpenToken'] or ''
	local secret = Properties ['SecretKey'] or ''

	if (token == '' or secret == '') then
		C4:UpdateProperty ('Connection Status', 'Not configured')
		DbgBasic ('waiting for OpenToken and SecretKey')
		return
	end

	-- Always re-run discovery. The Device Selection list is populated at
	-- runtime, so a driver update resets it to the XML placeholder and the
	-- dropdown would otherwise come back empty.
	DiscoverDevices ()

	if (GetDeviceId () ~= nil) then
		RefreshStatus ()
	end

	StartPolling ()
end

function OnPropertyChanged (strProperty)
	DbgVerbose ('property changed: ' .. tostring (strProperty))

	if (strProperty == 'OpenToken' or strProperty == 'SecretKey') then
		-- Credentials changed: drop any back-off and re-discover.
		State.failures = 0
		State.backoffUntil = 0

		local token  = Properties ['OpenToken'] or ''
		local secret = Properties ['SecretKey'] or ''
		if (token ~= '' and secret ~= '') then
			DiscoverDevices ()
			StartPolling ()
		else
			C4:UpdateProperty ('Connection Status', 'Not configured')
		end

	elseif (strProperty == 'Device Selection') then
		State.lockState = 'unknown'
		NotifyLockState ('unknown')
		RefreshStatus ()

	elseif (strProperty == 'Poll Frequency') then
		StartPolling ()
	end
end

-- Re-publish current contact state. Clearing the cache first forces a STATE_*
-- report rather than a transition, so re-binding never looks like the door just
-- opened or the lock just turned.
function ResendContactState ()
	State.contact = {}

	if (State.lockState == 'locked' or State.lockState == 'unlocked') then
		MirrorLockStateToContact (State.lockState)
	end

	if (State.doorState == 'open' or State.doorState == 'closed') then
		local doorClosed = (State.doorState == 'closed')
		if (Properties ['Door Contact Polarity'] == 'Closed = Door Open') then
			doorClosed = not doorClosed
		end
		NotifyContact (DOOR_STATE_BINDING, doorClosed)
	end

	DbgBasic ('re-sent contact state (lock=' .. tostring (State.lockState) ..
		', door=' .. tostring (State.doorState) .. ')')
end

-- Director calls this when a binding is connected or disconnected in Composer.
function OnBindingChanged (idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
	DbgBasic ('binding ' .. tostring (idBinding) .. ' (' .. tostring (strClass) ..
		') ' .. (bIsBound and 'bound' or 'unbound'))

	if (bIsBound and (idBinding == LOCK_STATE_BINDING or idBinding == DOOR_STATE_BINDING)) then
		State.contact [idBinding] = nil
		ResendContactState ()
	end
end

function OnDriverUpdate ()
	ReportVersion ('OnDriverUpdate')
	OnDriverLateInit ()
end

function OnDriverDestroyed ()
	DbgBasic ('OnDriverDestroyed - cleaning up timers')
	for name, _ in pairs (Timers) do
		CancelTimer (name)
	end
	Timers = {}
end
