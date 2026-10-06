--[[============================================================================
	Driver tests - run from the repository root:

	    lua5.4 tests/test_driver.lua

	Override the driver under test with DRIVER_LUA=/path/to/driver.lua.

	How it works
	  * The driver is loaded fresh for every test into its own environment.
	  * C4 is a mock: fake clock, timers that only fire when the test advances
	    time, and a fake SwitchBot cloud that answers HTTP requests from a
	    table the test controls (W.cloud).
	  * Timers are tables with a metatable, and the environment's type() reports
	    them as 'userdata' - the real Director returns userdata, and the driver's
	    CancelTimer checks for it.

	What this does NOT prove: that Director loads the driver, that proxy
	notifications are spelled the way Navigator expects, or that request
	signatures validate (C4:Hash is faked here). Those need a real controller.
==============================================================================]]

package.path = 'src/?.lua;tests/?.lua;' .. package.path

local DRIVER_PATH = os.getenv ('DRIVER_LUA') or 'src/driver.lua'
local rawtype = type

-- ============================================================================
-- JSON: use the project's sbjson when present, otherwise a minimal stand-in
-- ============================================================================

local function makeShim ()
	local J = {}
	local escmap = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

	local function isArray (t)
		local n = 0
		for k in pairs (t) do
			if (rawtype (k) ~= 'number') then return false end
			n = n + 1
		end
		return n > 0 and n == #t
	end

	local function enc (v)
		local t = rawtype (v)
		if (t == 'nil') then return 'null'
		elseif (t == 'boolean') then return tostring (v)
		elseif (t == 'number') then
			if (v == math.floor (v)) then return string.format ('%d', v) end
			return string.format ('%.14g', v)
		elseif (t == 'string') then
			return '"' .. (v:gsub ('[%c"\\]', function (c)
				return escmap [c] or string.format ('\\u%04x', c:byte ())
			end)) .. '"'
		elseif (t == 'table') then
			local parts = {}
			if (isArray (v)) then
				for i = 1, #v do parts [i] = enc (v [i]) end
				return '[' .. table.concat (parts, ',') .. ']'
			end
			local keys = {}
			for k in pairs (v) do keys [#keys + 1] = tostring (k) end
			table.sort (keys)
			for _, k in ipairs (keys) do parts [#parts + 1] = enc (k) .. ':' .. enc (v [k]) end
			return '{' .. table.concat (parts, ',') .. '}'
		end
		error ('cannot encode ' .. t)
	end

	local function dec (s)
		local pos = 1
		local value

		local function ws () pos = s:find ('%S', pos) or (#s + 1) end

		local function str ()
			local out = {}
			pos = pos + 1
			while (true) do
				local c = s:sub (pos, pos)
				if (c == '') then error ('unterminated string') end
				if (c == '"') then pos = pos + 1 break end
				if (c == '\\') then
					local n = s:sub (pos + 1, pos + 1)
					if (n == 'u') then
						out [#out + 1] = utf8.char (tonumber (s:sub (pos + 2, pos + 5), 16))
						pos = pos + 6
					else
						local m = { n = '\n', r = '\r', t = '\t' }
						out [#out + 1] = m [n] or n
						pos = pos + 2
					end
				else
					out [#out + 1] = c
					pos = pos + 1
				end
			end
			return table.concat (out)
		end

		function value ()
			ws ()
			local c = s:sub (pos, pos)
			if (c == '{') then
				local t = {}
				pos = pos + 1
				ws ()
				if (s:sub (pos, pos) == '}') then pos = pos + 1 return t end
				while (true) do
					ws ()
					local k = str ()
					ws ()
					assert (s:sub (pos, pos) == ':', 'expected :')
					pos = pos + 1
					t [k] = value ()
					ws ()
					local d = s:sub (pos, pos)
					pos = pos + 1
					if (d == '}') then return t end
					if (d ~= ',') then error ('bad object') end
				end
			elseif (c == '[') then
				local t = {}
				pos = pos + 1
				ws ()
				if (s:sub (pos, pos) == ']') then pos = pos + 1 return t end
				while (true) do
					t [#t + 1] = value ()
					ws ()
					local d = s:sub (pos, pos)
					pos = pos + 1
					if (d == ']') then return t end
					if (d ~= ',') then error ('bad array') end
				end
			elseif (c == '"') then return str ()
			elseif (s:sub (pos, pos + 3) == 'true') then pos = pos + 4 return true
			elseif (s:sub (pos, pos + 4) == 'false') then pos = pos + 5 return false
			elseif (s:sub (pos, pos + 3) == 'null') then pos = pos + 4 return nil
			end
			local num = s:match ('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
			assert (num and #num > 0, 'bad value')
			pos = pos + #num
			return tonumber (num)
		end

		local result = value ()
		ws ()
		assert (pos > #s, 'trailing data')
		return result
	end

	function J:encode (v) return enc (v) end
	function J:decode (s)
		local ok, r = pcall (dec, tostring (s))
		if (ok) then return r end
		return nil
	end
	return J
end

local JSON
do
	local ok, mod = pcall (require, 'sbjson')
	if (ok and rawtype (mod) == 'table') then
		JSON = mod
	else
		JSON = makeShim ()
	end
end

-- ============================================================================
-- Tiny test framework
-- ============================================================================

local passed, failed = 0, 0

local function eq (actual, expected, msg)
	if (actual ~= expected) then
		error (string.format ('%s: expected %s, got %s',
			msg or 'values differ', tostring (expected), tostring (actual)), 2)
	end
end

local function ok (cond, msg)
	if (not cond) then error (msg or 'assertion failed', 2) end
end

local function test (name, fn)
	local success, err = xpcall (fn, function (e) return e end)
	if (success) then
		passed = passed + 1
		print ('  ok    ' .. name)
	else
		failed = failed + 1
		print ('  FAIL  ' .. name)
		print ('        ' .. tostring (err))
	end
end

-- ============================================================================
-- The world: mocked C4, fake clock, fake SwitchBot cloud
-- ============================================================================

local TimerMT = { __index = { Cancel = function (self) self.cancelled = true end } }
local Transfer = {}
Transfer.__index = Transfer

local function hex (s)
	return (s:gsub ('.', function (c) return string.format ('%02x', c:byte ()) end))
end

local function newWorld (opts)
	opts = opts or {}

	local W = {
		now        = 1700000000000,		-- integer milliseconds
		seq        = 0,
		timers     = {},
		reqs       = {},
		pending    = {},
		proxy      = {},
		events     = {},
		errorLog   = {},
		out        = {},
		lists      = {},
		fireOnListUpdate = opts.fireOnListUpdate or false,
		cloud = {
			devices = opts.devices or {
				{ deviceId = 'LOCK123', deviceName = 'Front Door', deviceType = 'Smart Lock Ultra' },
			},
			status = {
				lockState = 'lock', doorState = 'closed', battery = 80, calibrate = true,
			},
			mode         = 'ok',		-- ok | transport | http500   (GET requests)
			commandMode  = 'ok',		-- same, for POST /commands
			hold         = false,		-- leave requests unanswered
			applyCommands = false,		-- a command instantly changes the cloud's lockState
		},
	}
	for k, v in pairs (opts.status or {}) do W.cloud.status [k] = v end

	local env = setmetatable ({}, { __index = _G })
	W.env = env

	-- The real Director returns userdata timers; the driver checks for it.
	env.type = function (v)
		if (rawtype (v) == 'table' and getmetatable (v) == TimerMT) then return 'userdata' end
		return rawtype (v)
	end
	env.require = function (name)
		if (name == 'sbjson') then return JSON end
		return require (name)
	end
	env.print = function (...)
		local parts = {}
		for i = 1, select ('#', ...) do parts [#parts + 1] = tostring ((select (i, ...))) end
		W.out [#W.out + 1] = table.concat (parts, '\t')
	end

	-- ---- C4 mock --------------------------------------------------------
	local C4 = {}
	env.C4 = C4

	function C4:GetTime () return W.now end
	function C4:AllowExecute () end
	function C4:ErrorLog (msg) W.errorLog [#W.errorLog + 1] = tostring (msg) end
	function C4:FireEvent (name) W.events [#W.events + 1] = name end
	function C4:Base64Encode (s) return 'B64' .. hex (s) end

	function C4:Hash (alg, data, o)
		-- Not a real SHA-256: deterministic 32 bytes, enough to exercise the
		-- signing plumbing. Real signature correctness needs a real controller.
		local sum = 0
		for i = 1, #data do sum = (sum * 31 + data:byte (i)) % 4294967291 end
		local bytes = {}
		for i = 1, 32 do
			sum = (sum * 1103515245 + 12345 + i) % 2147483648
			bytes [i] = string.char (sum % 256)
		end
		return table.concat (bytes)
	end

	function C4:SendToProxy (binding, cmd, params, kind)
		W.proxy [#W.proxy + 1] = { binding = binding, cmd = cmd, params = params or {}, kind = kind }
	end

	function C4:UpdateProperty (name, value)
		env.Properties [name] = value
	end

	function C4:UpdatePropertyList (name, csv, default)
		W.lists [name] = csv
		env.Properties [name] = default
		if (W.fireOnListUpdate) then env.OnPropertyChanged (name) end
	end

	function C4:SetTimer (delay, fn, rpt)
		local t = setmetatable ({}, TimerMT)
		W.seq = W.seq + 1
		t.seq, t.due, t.fn, t.rpt, t.interval = W.seq, W.now + delay, fn, rpt, delay
		W.timers [#W.timers + 1] = t
		return t
	end

	function C4:url () return setmetatable ({}, Transfer) end

	function Transfer:SetOptions (o) self.opts = o end
	function Transfer:OnDone (fn) self.done = fn return self end

	local function record (self, method, url, headers, body)
		local path = (url:gsub ('^https://api%.switch%-bot%.com', ''))
		local r = { method = method, url = url, path = path, headers = headers or {},
			body = body, transfer = self }
		W.reqs [#W.reqs + 1] = r
		W.pending [#W.pending + 1] = r
	end
	function Transfer:Get (url, headers) record (self, 'GET', url, headers, nil) end
	function Transfer:Post (url, data, headers) record (self, 'POST', url, headers, data) end

	-- ---- fake cloud -----------------------------------------------------
	function W.answer (r)
		local c = W.cloud
		local mode = (r.method == 'POST') and c.commandMode or c.mode
		local done, t = r.transfer.done, r.transfer

		if (mode == 'transport') then return done (t, nil, 28, 'timeout') end
		if (mode == 'http500') then
			return done (t, { { code = 500, body = '', headers = {} } }, 0, nil)
		end

		local body
		if (r.method == 'POST') then
			if (c.applyCommands) then
				local cmd = JSON:decode (r.body)
				if (cmd and cmd.command == 'lock') then c.status.lockState = 'lock' end
				if (cmd and cmd.command == 'unlock') then c.status.lockState = 'unlock' end
			end
			body = { statusCode = 100, message = 'success', body = {} }
		elseif (r.path == '/v1.1/devices') then
			body = { statusCode = 100, message = 'success', body = { deviceList = c.devices } }
		else
			body = { statusCode = 100, message = 'success', body = c.status }
		end
		done (t, { { code = 200, body = JSON:encode (body), headers = {} } }, 0, nil)
	end

	function W.settle ()
		local guard = 0
		while (not W.cloud.hold and #W.pending > 0) do
			guard = guard + 1
			assert (guard < 1000, 'settle loop')
			W.answer (table.remove (W.pending, 1))
		end
	end

	function W.release ()
		W.cloud.hold = false
		W.settle ()
	end

	-- Move the clock forward, firing timers in time order and answering HTTP
	-- requests as they are made.
	function W.advance (ms)
		local target = W.now + ms
		local guard = 0
		while (true) do
			W.settle ()
			local best
			for _, t in ipairs (W.timers) do
				if (not t.cancelled and t.due <= target) then
					if (not best or t.due < best.due or (t.due == best.due and t.seq < best.seq)) then
						best = t
					end
				end
			end
			if (not best) then break end
			guard = guard + 1
			assert (guard < 100000, 'advance loop')
			if (best.due > W.now) then W.now = best.due end
			if (best.rpt) then best.due = best.due + best.interval else best.cancelled = true end
			best.fn (best, 0)
		end
		W.now = target
		W.settle ()
	end

	-- ---- boot -----------------------------------------------------------
	function W.boot (o)
		o = o or {}
		local props = {
			['Driver Version']         = '1.2.0',
			['OpenToken']              = 'TOKEN-ABC-123',
			['SecretKey']              = 'SECRET-XYZ-789',
			['Device Selection']       = 'Front Door (LOCK123)',
			['Partial Lock Reports As'] = 'Unlocked',
			['Poll Frequency']         = '60 seconds',
			['Lock Contact Polarity']  = 'Closed = Locked',
			['Door Contact Polarity']  = 'Closed = Door Shut',
			['Debug Mode']             = 'Off',
		}
		for k, v in pairs (opts.props or {}) do props [k] = v end
		env.Properties = props

		local f = assert (io.open (DRIVER_PATH, 'r'), 'cannot open ' .. DRIVER_PATH)
		local src = f:read ('a')
		f:close ()
		local chunk = assert (load (src, '@' .. DRIVER_PATH, 't', env))
		chunk ()

		env.OnDriverInit ()

		-- Director replays every saved property through OnPropertyChanged
		-- during load, before OnDriverLateInit.
		if (o.replay ~= false) then
			local names = {}
			for k in pairs (props) do names [#names + 1] = k end
			table.sort (names)
			for _, name in ipairs (names) do env.OnPropertyChanged (name) end
		end

		env.OnDriverLateInit ()
		W.settle ()
	end

	-- ---- inspection helpers --------------------------------------------
	function W.clear ()
		W.reqs, W.pending, W.proxy, W.events, W.errorLog, W.out = {}, {}, {}, {}, {}, {}
	end

	function W.count (method, pattern)
		local n = 0
		for _, r in ipairs (W.reqs) do
			if (r.method == method and r.path:find (pattern)) then n = n + 1 end
		end
		return n
	end

	function W.statusReads () return W.count ('GET', '/status$') end
	function W.commands ()    return W.count ('POST', '/commands$') end
	function W.discoveries () return W.count ('GET', '^/v1.1/devices$') end

	function W.eventCount (name)
		local n = 0
		for _, e in ipairs (W.events) do if (e == name) then n = n + 1 end end
		return n
	end

	function W.errCount (pattern)
		local n = 0
		for _, e in ipairs (W.errorLog) do if (e:find (pattern, 1, true)) then n = n + 1 end end
		return n
	end

	function W.proxyOf (cmd, binding)
		local r = {}
		for _, p in ipairs (W.proxy) do
			if (p.cmd == cmd and (binding == nil or p.binding == binding)) then r [#r + 1] = p end
		end
		return r
	end

	function W.lastChanged ()
		local l = W.proxyOf ('LOCK_STATUS_CHANGED')
		return l [#l]
	end

	function W.prop (name) return env.Properties [name] end
	function W.proxyCommand (cmd) env.ReceivedFromProxy (5001, cmd, {}) W.settle () end

	return W
end

-- ============================================================================
-- Tests
-- ============================================================================

print ('Boot and basic reporting')

test ('no credentials: reports unknown to the proxy and makes no requests', function ()
	local W = newWorld { props = { OpenToken = '', SecretKey = '' } }
	W.boot ()
	eq (#W.reqs, 0, 'requests')
	eq (W.prop ('Connection Status'), 'Not configured')
	local init = W.proxyOf ('LOCK_STATUS_INITIALIZE')
	eq (#init, 1, 'initialize count')
	eq (init [1].params.LOCK_STATUS, 'unknown')
end)

test ('LOCK_STATUS_INITIALIZE is sent before any LOCK_STATUS_CHANGED', function ()
	local W = newWorld ()
	W.boot ()
	eq (W.proxy [1].cmd, 'LOCK_STATUS_INITIALIZE')
	eq (W.lastChanged ().params.LOCK_STATUS, 'locked')
end)

test ('the headers carry the signing fields', function ()
	local W = newWorld ()
	W.boot ()
	local h = W.reqs [1].headers
	eq (h ['Authorization'], 'TOKEN-ABC-123')
	ok (h ['sign'] and #h ['sign'] > 0, 'sign missing')
	eq (h ['sign'], h ['sign']:upper (), 'sign must be uppercase')
	ok (tonumber (h ['t']), 't must be numeric')
	ok (h ['nonce'] and #h ['nonce'] > 0, 'nonce missing')
end)

test ('token and secret never reach the log, even in Verbose', function ()
	local W = newWorld { props = { ['Debug Mode'] = 'Verbose' } }
	W.boot ()
	W.cloud.status.lockState = 'unlock'
	W.advance (61000)
	W.proxyCommand ('LOCK')
	W.advance (20000)
	local all = table.concat (W.out, '\n') .. '\n' .. table.concat (W.errorLog, '\n')
	ok (#W.out > 20, 'verbose logging should be producing output')
	ok (all:find ('<redacted>', 1, true), 'expected redaction marker')
	ok (not all:find ('TOKEN-ABC-123', 1, true), 'token leaked')
	ok (not all:find ('SECRET-XYZ-789', 1, true), 'secret key leaked')
end)

print ('\nLock state mapping')

for _, c in ipairs {
	{ 'lock', 'locked' }, { 'LOCKED', 'locked' }, { 'unlock', 'unlocked' },
	{ 'halfLocked', 'unlocked' }, { 'latchBoltLocked', 'unlocked' },
	{ 'NOT_FULLY_LOCKED', 'unlocked' },
	{ 'jammed', 'fault' }, { 'LOCKING_STOP', 'fault' }, { 'unlockingBlocked', 'fault' },
	{ 'somethingNew', 'unknown' },
} do
	test ('lockState "' .. c [1] .. '" -> ' .. c [2], function ()
		local W = newWorld { status = { lockState = c [1] } }
		W.boot ()
		eq (W.prop ('Lock Status'), c [2])
	end)
end

test ('unrecognised lockState logs the full payload so it can be mapped', function ()
	local W = newWorld { status = { lockState = 'somethingNew' } }
	W.boot ()
	ok (W.errCount ('somethingNew') >= 2, 'expected the payload in the error log')
end)

test ('uncalibrated lock reports fault', function ()
	local W = newWorld { status = { calibrate = false } }
	W.boot ()
	eq (W.prop ('Lock Status'), 'fault')
	eq (W.prop ('Lock Detail'), 'Not calibrated')
end)

test ('partial lock reports Locked when the dealer chose that, door shut', function ()
	local W = newWorld { status = { lockState = 'halfLocked' },
		props = { ['Partial Lock Reports As'] = 'Locked' } }
	W.boot ()
	eq (W.prop ('Lock Status'), 'locked')
end)

test ('SAFETY: partial lock with the door open is never locked, even if set to Locked', function ()
	local W = newWorld { status = { lockState = 'latchBoltLocked', doorState = 'opened' },
		props = { ['Partial Lock Reports As'] = 'Locked' } }
	W.boot ()
	eq (W.prop ('Lock Status'), 'unlocked')
end)

test ('TOGGLE from an unknown state refuses to actuate', function ()
	local W = newWorld { status = { lockState = 'somethingNew' } }
	W.boot ()
	W.clear ()
	W.proxyCommand ('TOGGLE')
	eq (W.commands (), 0, 'commands sent')
	ok (W.statusReads () >= 1, 'should refresh instead')
end)

test ('relay CLOSE sends the lock command, OPEN sends unlock', function ()
	local W = newWorld ()
	W.cloud.applyCommands = true
	W.boot ()
	W.clear ()
	W.env.ReceivedFromProxy (300, 'OPEN', {})
	W.advance (20000)
	local body
	for _, r in ipairs (W.reqs) do if (r.method == 'POST') then body = JSON:decode (r.body) end end
	eq (body.command, 'unlock')
	W.clear ()
	W.env.ReceivedFromProxy (300, 'CLOSE', {})
	W.advance (20000)
	for _, r in ipairs (W.reqs) do if (r.method == 'POST') then body = JSON:decode (r.body) end end
	eq (body.command, 'lock')
end)

test ('a second command while one is in flight is ignored', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.cloud.hold = true
	W.proxyCommand ('UNLOCK')
	W.proxyCommand ('LOCK')
	eq (W.commands (), 1, 'commands sent')
	W.release ()
end)

print ('\nStartup behaviour')

test ('boot with saved properties makes one discovery and one status read', function ()
	local W = newWorld ()
	W.boot ()		-- replays every property through OnPropertyChanged, as Director does
	eq (W.discoveries (), 1, 'discovery calls')
	eq (W.statusReads (), 1, 'status reads')
	eq (W.commands (), 0, 'commands')
end)

test ('property changes before OnDriverLateInit are ignored', function ()
	local W = newWorld ()
	W.boot { replay = false }
	W.clear ()
	-- simulate a replay arriving after init: those must still be harmless to
	-- count, and State.ready gates the early ones
	W.env.State.ready = false
	W.env.OnPropertyChanged ('OpenToken')
	W.env.OnPropertyChanged ('SecretKey')
	W.env.OnPropertyChanged ('Device Selection')
	W.advance (5000)
	eq (#W.reqs, 0, 'requests while not ready')
end)

test ('first reading after boot is an initial sync, not a manual action', function ()
	local W = newWorld ()
	W.boot ()
	local changed = W.proxyOf ('LOCK_STATUS_CHANGED')
	eq (#changed, 1)
	eq (changed [1].params.LOCK_STATUS, 'locked')
	eq (changed [1].params.MANUAL, false, 'MANUAL')
	eq (changed [1].params.SOURCE, 'SwitchBot')
	eq (changed [1].params.LAST_ACTION_DESCRIPTION, 'Initial state')
end)

test ('first door reading fires no Door Opened / Door Closed event', function ()
	local W = newWorld ()
	W.boot ()
	eq (W.eventCount ('Door Closed'), 0)
	eq (W.eventCount ('Door Opened'), 0)
	eq (W.prop ('Door Status'), 'closed')
end)

test ('a later change at the lock IS reported as manual', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.cloud.status.lockState = 'unlock'
	W.advance (60000)
	local c = W.lastChanged ()
	eq (c.params.LOCK_STATUS, 'unlocked')
	eq (c.params.MANUAL, true, 'MANUAL')
	eq (c.params.LAST_ACTION_DESCRIPTION, 'Changed at the lock')
end)

test ('door found open at boot: no Door Opened event, but Door Left Open still fires', function ()
	local W = newWorld { status = { doorState = 'opened' } }
	W.boot ()
	eq (W.eventCount ('Door Opened'), 0)
	eq (W.prop ('Door Status'), 'open')
	W.advance (5 * 60 * 1000 + 1000)
	eq (W.eventCount ('Door Left Open'), 1)
	W.advance (3 * 60 * 1000)
	eq (W.eventCount ('Door Left Open'), 1, 'must fire once')
end)

test ('real door transitions after the initial sync fire events', function ()
	local W = newWorld ()
	W.boot ()
	W.cloud.status.doorState = 'opened'
	W.advance (60000)
	eq (W.eventCount ('Door Opened'), 1)
	W.cloud.status.doorState = 'closed'
	W.advance (60000)
	eq (W.eventCount ('Door Closed'), 1)
end)

test ('entering OpenToken then SecretKey at runtime causes one discovery', function ()
	local W = newWorld { fireOnListUpdate = true,
		props = { OpenToken = '', SecretKey = '', ['Device Selection'] = 'Select a device...' } }
	W.boot ()
	eq (#W.reqs, 0)
	W.env.Properties.OpenToken = 'tok'
	W.env.OnPropertyChanged ('OpenToken')
	W.advance (500)
	W.env.Properties.SecretKey = 'sec'
	W.env.OnPropertyChanged ('SecretKey')
	W.advance (3000)
	eq (W.discoveries (), 1, 'discovery calls')
	-- discovery selected the lock, which refreshed it once
	eq (W.statusReads (), 1, 'status reads')
	eq (W.prop ('Lock Status'), 'locked')
	-- and polling is running
	W.advance (61000)
	eq (W.statusReads (), 2, 'status reads after one poll')
end)

test ('replacing both existing credentials within the debounce window causes one discovery', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.env.Properties.OpenToken = 'new-token'
	W.env.OnPropertyChanged ('OpenToken')
	W.advance (500)
	W.env.Properties.SecretKey = 'new-secret'
	W.env.OnPropertyChanged ('SecretKey')
	W.advance (3000)
	eq (W.discoveries (), 1, 'discovery calls')
end)

test ('re-selecting the same lock (even renamed) costs nothing', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.env.Properties ['Device Selection'] = 'Front Door (LOCK123)'
	W.env.OnPropertyChanged ('Device Selection')
	W.env.Properties ['Device Selection'] = 'Front Door Renamed (LOCK123)'
	W.env.OnPropertyChanged ('Device Selection')
	W.advance (3000)
	eq (#W.reqs, 0, 'requests')
	eq (#W.proxyOf ('LOCK_STATUS_CHANGED'), 0, 'proxy notifications')
end)

test ('selecting a different lock resets state, tells the proxy, and re-reads', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.env.Properties ['Device Selection'] = 'Back Door (LOCK456)'
	W.env.OnPropertyChanged ('Device Selection')
	W.settle ()
	local seen = {}
	for _, p in ipairs (W.proxyOf ('LOCK_STATUS_CHANGED')) do seen [#seen + 1] = p.params.LOCK_STATUS end
	eq (seen [1], 'unknown', 'proxy must be told about the reset first')
	eq (seen [2], 'locked', 'then the new lock state')
	local hit = false
	for _, r in ipairs (W.reqs) do if (r.path:find ('LOCK456')) then hit = true end end
	ok (hit, 'expected a status read for the new device')
	eq (W.lastChanged ().params.MANUAL, false, 'a fresh device is an initial sync')
end)

print ('\nBack-off')

test ('a command still goes out while the driver is backing off', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.cloud.mode = 'http500'
	W.advance (60000)					-- the poll fails; back-off begins
	ok (W.env.State.backoffUntil > W.now, 'should be in back-off')
	W.cloud.mode = 'ok'
	W.clear ()

	W.env.RefreshStatus ()				-- background refresh: suppressed
	W.settle ()
	eq (W.statusReads (), 0, 'background refresh must stay suppressed')

	W.proxyCommand ('UNLOCK')			-- user command: must not be
	eq (W.commands (), 1, 'commands sent')
end)

test ('a failed command still triggers the verification read', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.cloud.commandMode = 'http500'
	W.proxyCommand ('UNLOCK')
	eq (W.commands (), 1)
	ok (W.statusReads () >= 1, 'verification read was suppressed by back-off')
	eq (W.env.State.pendingCommand, nil, 'pending command must be cleared')
	eq (W.env.State.inFlight, false, 'inFlight must be cleared')
	eq (W.prop ('Lock Status'), 'locked', 'UI must show the real state')
end)

test ('manual actions bypass back-off', function ()
	local W = newWorld ()
	W.boot ()
	W.cloud.mode = 'http500'
	W.advance (60000)
	W.cloud.mode = 'ok'
	W.clear ()
	W.env.ExecuteCommand ('LUA_ACTION', { ACTION = 'Refresh Status' })
	W.env.ExecuteCommand ('LUA_ACTION', { ACTION = 'Test Connection' })
	W.settle ()
	eq (W.statusReads (), 1)
	eq (W.discoveries (), 1)
end)

test ('stale data is reported unknown, and recovery is an initial sync', function ()
	local W = newWorld ()
	W.boot ()
	W.cloud.mode = 'transport'
	W.advance (190000)
	eq (W.env.State.stale, true)
	eq (W.prop ('Lock Status'), 'unknown')
	ok ((W.prop ('Lock Detail') or ''):find ('^STALE'), 'Lock Detail should say STALE')
	W.cloud.mode = 'ok'
	W.clear ()
	W.advance (80000)
	eq (W.env.State.stale, false)
	eq (W.prop ('Lock Status'), 'locked')
	eq (W.prop ('Connection Status'), 'Connected')
	eq (W.lastChanged ().params.MANUAL, false, 'recovery must not look like a keypad')
end)

print ('\nCommand confirmation')

test ('the cloud acking a command does not by itself change reported state', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.proxyCommand ('UNLOCK')
	eq (#W.proxyOf ('LOCK_STATUS_CHANGED'), 0, 'nothing reported on ack alone')
	eq (W.prop ('Lock Status'), 'locked')
end)

test ('telemetry lagging the motor is not a failure; confirms at the next read', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.proxyCommand ('UNLOCK')
	W.advance (2000)						-- first verification: cloud still says locked
	eq (W.errCount ('did not take effect'), 0, 'false failure at 2s')
	ok (W.env.State.pendingCommand ~= nil, 'still pending')
	W.cloud.status.lockState = 'unlock'
	W.advance (4000)						-- second verification, at 6s
	local c = W.lastChanged ()
	eq (c.params.LOCK_STATUS, 'unlocked')
	eq (c.params.MANUAL, false, 'MANUAL')
	eq (c.params.SOURCE, 'Control4')
	eq (W.env.State.pendingCommand, nil, 'confirmed')
	eq (W.errCount ('did not take effect'), 0)
	local reads = W.statusReads ()
	W.advance (15000)
	eq (W.statusReads (), reads, 'remaining verification reads must be cancelled')
end)

test ('confirmed on the first read costs exactly one verification read', function ()
	local W = newWorld ()
	W.cloud.applyCommands = true
	W.boot ()
	W.clear ()
	W.proxyCommand ('UNLOCK')
	W.advance (20000)
	eq (W.statusReads (), 1, 'verification reads')
	eq (W.lastChanged ().params.LOCK_STATUS, 'unlocked')
end)

test ('an unconfirmed command expires, and later keypad changes are not blamed on Control4', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.proxyCommand ('UNLOCK')
	W.advance (20000)						-- cloud never changes
	eq (W.errCount ('not confirmed within'), 1, 'expiry error')
	eq (W.errCount ('did not take effect'), 0)
	eq (W.env.State.pendingCommand, nil, 'pending must be cleared')

	W.cloud.status.lockState = 'unlock'		-- someone uses the keypad
	W.advance (45000)						-- next poll
	local c = W.lastChanged ()
	eq (c.params.LOCK_STATUS, 'unlocked')
	eq (c.params.MANUAL, true, 'must be attributed to the door, not Control4')
end)

test ('a fault during a command ends it immediately', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.proxyCommand ('UNLOCK')
	W.cloud.status.lockState = 'unlockingStop'
	W.advance (2000)
	eq (W.prop ('Lock Status'), 'fault')
	eq (W.errCount ('device reports a fault'), 1)
	eq (W.env.State.pendingCommand, nil)
end)

print ('\nFault events')

test ('Lock Jammed fires once per jam, not once per poll', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.cloud.status.lockState = 'jammed'
	W.advance (180000)
	eq (W.eventCount ('Lock Jammed'), 1, 'during a persistent jam')
	eq (W.prop ('Lock Status'), 'fault')
	W.cloud.status.lockState = 'lock'
	W.advance (60000)
	W.cloud.status.lockState = 'jammed'
	W.advance (120000)
	eq (W.eventCount ('Lock Jammed'), 2, 'a new jam after recovery')
end)

test ('Calibration Error fires once while the fault persists', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.cloud.status.calibrate = false
	W.advance (180000)
	eq (W.eventCount ('Calibration Error'), 1)
	W.cloud.status.calibrate = true
	W.advance (60000)
	W.cloud.status.calibrate = false
	W.advance (60000)
	eq (W.eventCount ('Calibration Error'), 2)
end)

print ('\nTransitional states')

test ('a stuck locking state is re-polled a bounded number of times, then unknown', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.cloud.status.lockState = 'locking'
	W.advance (60000)						-- the poll
	W.advance (30000)						-- the re-checks
	eq (W.statusReads (), 7, 'one poll + six re-checks')
	eq (W.env.State.lockState, 'unknown')
	ok ((W.prop ('Lock Detail') or ''):find ('^Stuck'), 'Lock Detail should say Stuck')
	eq (W.errCount ('still reports'), 1)
	W.advance (40000)						-- includes the next regular poll
	eq (W.statusReads (), 8, 'only the regular poll, no new re-check loop')
	eq (W.errCount ('still reports'), 1, 'error must not repeat')
end)

test ('a brief locking state resolves without being reported unknown', function ()
	local W = newWorld ()
	W.boot ()
	W.clear ()
	W.cloud.status.lockState = 'unlocking'
	W.advance (60000)
	eq (W.env.State.lockState, 'locked', 'last known state is held mid-travel')
	W.cloud.status.lockState = 'unlock'
	W.advance (2000)
	eq (W.env.State.lockState, 'unlocked')
end)

print ('\nBattery and contacts')

test ('Low Battery fires once per crossing below 15%, and re-arms above it', function ()
	local W = newWorld { status = { battery = 14 } }
	W.boot ()
	eq (W.eventCount ('Low Battery'), 1)
	W.advance (180000)
	eq (W.eventCount ('Low Battery'), 1, 'must not repeat')
	W.cloud.status.battery = 40
	W.advance (60000)
	W.cloud.status.battery = 10
	W.advance (60000)
	eq (W.eventCount ('Low Battery'), 2)
end)

test ('exactly 15% is not low', function ()
	local W = newWorld { status = { battery = 15 } }
	W.boot ()
	eq (W.eventCount ('Low Battery'), 0)
	local b = W.proxyOf ('BATTERY_STATUS_CHANGED')
	eq (b [1].params.BATTERY_STATUS, 'normal')
end)

test ('battery status is sent when its band changes, not every poll', function ()
	local W = newWorld ()
	W.boot ()
	eq (#W.proxyOf ('BATTERY_STATUS_CHANGED'), 1)
	W.advance (180000)
	eq (#W.proxyOf ('BATTERY_STATUS_CHANGED'), 1)
end)

test ('contacts: state on first report, transition only on change', function ()
	local W = newWorld ()
	W.boot ()
	local first = W.proxyOf ('STATE_CLOSED', 400)
	eq (#first, 1, 'initial lock contact state')
	eq (#W.proxyOf ('CLOSED', 400), 0, 'no transition on first report')
	W.advance (180000)
	eq (#W.proxyOf ('STATE_CLOSED', 400), 1, 'unchanged polls say nothing')
	W.cloud.status.lockState = 'unlock'
	W.advance (60000)
	eq (#W.proxyOf ('OPENED', 400), 1, 'one transition')
end)

test ('contact polarity can be inverted', function ()
	local W = newWorld { props = { ['Lock Contact Polarity'] = 'Closed = Unlocked' } }
	W.boot ()
	eq (#W.proxyOf ('STATE_OPENED', 400), 1, 'locked reports OPENED when inverted')
end)

-- ============================================================================

print (string.format ('\n%d passed, %d failed', passed, failed))
os.exit (failed == 0 and 0 or 1)
