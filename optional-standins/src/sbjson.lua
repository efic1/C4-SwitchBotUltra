--[[============================================================================
	sbjson.lua - self-contained JSON encode/decode

	STAND-IN. This file was written to complete a build when the repository's
	own src/sbjson.lua was not available. If you have the original (the one
	covered by tests/test_json.lua), copy it over this file and rebuild.

	API (matches what driver.lua uses):
	    JSON:encode (value)  -> string, or nil on failure
	    JSON:decode (string) -> value, or nil on malformed input

	Lua 5.1 compatible: no goto, no integer division, no utf8 library.
	JSON null decodes to nil (so it is dropped from objects).
==============================================================================]]

local JSON = {}

local floor, format, char, byte = math.floor, string.format, string.char, string.byte
local concat = table.concat

-- ----------------------------------------------------------------------------
-- UTF-8
-- ----------------------------------------------------------------------------

local function utf8char (cp)
	if (cp < 0x80) then
		return char (cp)
	elseif (cp < 0x800) then
		return char (0xC0 + floor (cp / 0x40), 0x80 + cp % 0x40)
	elseif (cp < 0x10000) then
		return char (0xE0 + floor (cp / 0x1000),
			0x80 + floor (cp / 0x40) % 0x40,
			0x80 + cp % 0x40)
	else
		return char (0xF0 + floor (cp / 0x40000),
			0x80 + floor (cp / 0x1000) % 0x40,
			0x80 + floor (cp / 0x40) % 0x40,
			0x80 + cp % 0x40)
	end
end

-- ----------------------------------------------------------------------------
-- Encode
-- ----------------------------------------------------------------------------

local ESCAPES = {
	['"']  = '\\"',  ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
	['\n'] = '\\n',  ['\r'] = '\\r',  ['\t'] = '\\t',
}

local function encodeString (s)
	return '"' .. s:gsub ('[%c"\\]', function (c)
		return ESCAPES [c] or format ('\\u%04x', byte (c))
	end) .. '"'
end

local function isArray (t)
	local n = 0
	for k in pairs (t) do
		if (type (k) ~= 'number' or k < 1 or k ~= floor (k)) then return false end
		n = n + 1
	end
	return n > 0 and n == #t
end

local encodeValue

local function encodeTable (t, seen)
	if (seen [t]) then error ('circular reference') end
	seen [t] = true

	local parts = {}
	if (isArray (t)) then
		for i = 1, #t do parts [i] = encodeValue (t [i], seen) end
		seen [t] = nil
		return '[' .. concat (parts, ',') .. ']'
	end

	local keys = {}
	for k in pairs (t) do
		if (type (k) ~= 'string' and type (k) ~= 'number') then
			error ('unsupported key type: ' .. type (k))
		end
		keys [#keys + 1] = tostring (k)
	end
	table.sort (keys)

	for _, k in ipairs (keys) do
		local v = t [k]
		if (v == nil) then v = t [tonumber (k)] end
		parts [#parts + 1] = encodeString (k) .. ':' .. encodeValue (v, seen)
	end
	seen [t] = nil
	return '{' .. concat (parts, ',') .. '}'
end

function encodeValue (v, seen)
	local t = type (v)
	if (t == 'nil') then
		return 'null'
	elseif (t == 'boolean') then
		return v and 'true' or 'false'
	elseif (t == 'number') then
		if (v ~= v or v == math.huge or v == -math.huge) then
			error ('cannot encode non-finite number')
		end
		if (v == floor (v) and v > -1e15 and v < 1e15) then
			return format ('%d', v)
		end
		return format ('%.14g', v)
	elseif (t == 'string') then
		return encodeString (v)
	elseif (t == 'table') then
		return encodeTable (v, seen)
	end
	error ('cannot encode ' .. t)
end

function JSON:encode (value)
	local ok, result = pcall (encodeValue, value, {})
	if (ok) then return result end
	return nil
end

-- ----------------------------------------------------------------------------
-- Decode
-- ----------------------------------------------------------------------------

local SIMPLE_ESCAPES = {
	['"'] = '"', ['\\'] = '\\', ['/'] = '/',
	b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

local function decode (s)
	local pos = 1
	local value

	local function skip ()
		pos = s:find ('[^ \t\r\n]', pos) or (#s + 1)
	end

	local function fail (msg)
		error ('JSON: ' .. msg .. ' at position ' .. pos, 0)
	end

	local function readString ()
		-- pos is on the opening quote
		pos = pos + 1
		local out = {}
		while (true) do
			local stop = s:find ('["\\]', pos)
			if (not stop) then fail ('unterminated string') end
			if (stop > pos) then out [#out + 1] = s:sub (pos, stop - 1) end

			if (s:sub (stop, stop) == '"') then
				pos = stop + 1
				return concat (out)
			end

			local esc = s:sub (stop + 1, stop + 1)
			if (esc == 'u') then
				local hex = s:sub (stop + 2, stop + 5)
				if (not hex:match ('^%x%x%x%x$')) then fail ('bad \\u escape') end
				local cp = tonumber (hex, 16)
				pos = stop + 6

				-- surrogate pair
				if (cp >= 0xD800 and cp <= 0xDBFF) then
					local low = s:match ('^\\u(%x%x%x%x)', pos)
					local lowCp = low and tonumber (low, 16)
					if (lowCp and lowCp >= 0xDC00 and lowCp <= 0xDFFF) then
						cp = 0x10000 + (cp - 0xD800) * 0x400 + (lowCp - 0xDC00)
						pos = pos + 6
					else
						cp = 0xFFFD
					end
				elseif (cp >= 0xDC00 and cp <= 0xDFFF) then
					cp = 0xFFFD
				end
				out [#out + 1] = utf8char (cp)
			else
				local mapped = SIMPLE_ESCAPES [esc]
				if (not mapped) then fail ('bad escape \\' .. esc) end
				out [#out + 1] = mapped
				pos = stop + 2
			end
		end
	end

	local function readNumber ()
		local num = s:match ('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
		if (not num or num == '' or num == '-') then fail ('bad number') end
		local n = tonumber (num)
		if (n == nil) then fail ('bad number') end
		pos = pos + #num
		return n
	end

	local function expectLiteral (word, result)
		if (s:sub (pos, pos + #word - 1) ~= word) then fail ('unexpected token') end
		pos = pos + #word
		return result
	end

	function value ()
		skip ()
		local c = s:sub (pos, pos)

		if (c == '{') then
			local t = {}
			pos = pos + 1
			skip ()
			if (s:sub (pos, pos) == '}') then pos = pos + 1 return t end
			while (true) do
				skip ()
				if (s:sub (pos, pos) ~= '"') then fail ('expected object key') end
				local k = readString ()
				skip ()
				if (s:sub (pos, pos) ~= ':') then fail ('expected :') end
				pos = pos + 1
				t [k] = value ()
				skip ()
				local d = s:sub (pos, pos)
				pos = pos + 1
				if (d == '}') then return t end
				if (d ~= ',') then fail ('expected , or }') end
			end

		elseif (c == '[') then
			local t = {}
			local n = 0
			pos = pos + 1
			skip ()
			if (s:sub (pos, pos) == ']') then pos = pos + 1 return t end
			while (true) do
				n = n + 1
				t [n] = value ()
				skip ()
				local d = s:sub (pos, pos)
				pos = pos + 1
				if (d == ']') then return t end
				if (d ~= ',') then fail ('expected , or ]') end
			end

		elseif (c == '"') then
			return readString ()
		elseif (c == 't') then
			return expectLiteral ('true', true)
		elseif (c == 'f') then
			return expectLiteral ('false', false)
		elseif (c == 'n') then
			return expectLiteral ('null', nil)
		elseif (c == '') then
			fail ('unexpected end of input')
		end

		return readNumber ()
	end

	local result = value ()
	skip ()
	if (pos <= #s) then fail ('trailing data') end
	return result
end

function JSON:decode (s)
	if (type (s) ~= 'string' or s == '') then return nil end
	local ok, result = pcall (decode, s)
	if (ok) then return result end
	return nil
end

return JSON
