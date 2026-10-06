-- Run from the repository root:  lua tests/test_json.lua
-- Works under Lua 5.1 and 5.4.
package.path = 'src/?.lua;' .. package.path
local JSON = require ('sbjson')

local passed, failed = 0, 0
local function check (name, cond)
	if (cond) then passed = passed + 1 else failed = failed + 1 print ('  FAIL  ' .. name) end
end
local function same (a, b)
	if (type (a) ~= type (b)) then return false end
	if (type (a) ~= 'table') then return a == b end
	for k, v in pairs (a) do if (not same (v, b [k])) then return false end end
	for k in pairs (b) do if (a [k] == nil) then return false end end
	return true
end
local function roundtrip (name, v)
	check ('roundtrip: ' .. name, same (JSON:decode (JSON:encode (v)), v))
end

-- decode: shapes SwitchBot actually returns
local api = JSON:decode ('{"statusCode":100,"body":{"deviceList":[{"deviceId":"ABC","deviceName":"Front Door","deviceType":"Smart Lock Ultra"}],"infraredRemoteList":[]},"message":"success"}')
check ('api: statusCode', api and api.statusCode == 100)
check ('api: nested array', api and api.body.deviceList [1].deviceName == 'Front Door')
check ('api: empty array', api and type (api.body.infraredRemoteList) == 'table')

local st = JSON:decode ('{"lockState":"locked","doorState":"closed","battery":87,"calibrate":true,"x":null}')
check ('status: fields', st and st.lockState == 'locked' and st.battery == 87 and st.calibrate == true)
check ('status: null dropped', st and st.x == nil)

-- numbers
check ('number: negative', JSON:decode ('-12') == -12)
check ('number: float', JSON:decode ('3.5') == 3.5)
check ('number: exponent', JSON:decode ('1e3') == 1000)
check ('number: zero', JSON:decode ('0') == 0)

-- strings and escapes
check ('escape: quote and backslash', JSON:decode ('"a\\"b\\\\c"') == 'a"b\\c')
check ('escape: newline/tab', JSON:decode ('"a\\nb\\tc"') == 'a\nb\tc')
check ('escape: \\u00e9', JSON:decode ('"\\u00e9"') == '\195\169')
check ('escape: surrogate pair', JSON:decode ('"\\ud83d\\ude00"') == '\240\159\152\128')
check ('escape: lone surrogate is replaced, not a crash', JSON:decode ('"\\ud83d"') == '\239\191\189')
check ('raw utf-8 passes through', JSON:decode ('"\195\169"') == '\195\169')

-- malformed input returns nil rather than throwing
for _, bad in ipairs { '', '{', '{"a":}', '[1,2', '{"a":1,}', '"abc', 'nope', '{"a":1} x', '[1 2]', '{1:2}' } do
	check ('malformed -> nil: ' .. bad, JSON:decode (bad) == nil)
end
check ('non-string -> nil', JSON:decode (nil) == nil and JSON:decode (42) == nil)

-- encode
check ('encode: object is deterministic', JSON:encode ({ b = 1, a = 2 }) == '{"a":2,"b":1}')
check ('encode: array', JSON:encode ({ 1, 2, 3 }) == '[1,2,3]')
check ('encode: string escapes', JSON:encode ('a"b\n') == '"a\\"b\\n"')
check ('encode: control char', JSON:encode ('\1') == '"\\u0001"')
check ('encode: integer-valued float has no decimal', JSON:encode (5.0) == '5')
check ('encode: nested', JSON:encode ({ command = 'lock', parameter = 'default', commandType = 'command' })
	== '{"command":"lock","commandType":"command","parameter":"default"}')
check ('encode: NaN fails safely', JSON:encode (0 / 0) == nil)
local loop = {} loop.self = loop
check ('encode: circular fails safely', JSON:encode (loop) == nil)

-- roundtrips
roundtrip ('mixed', { a = 1, b = { 'x', 'y' }, c = { d = true, e = false }, s = 'é "q" \\ \n' })
roundtrip ('deep', { a = { b = { c = { d = { 1, 2, { e = 'f' } } } } } })

print (string.format ('%d passed, %d failed', passed, failed))
os.exit (failed == 0 and 0 or 1)
