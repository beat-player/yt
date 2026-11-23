-- Blocking HTTP over curl-sys's easy handle. Every call here waits for its transfer; run it on a
-- thread when the caller cannot.
--
-- libcurl calls back into Lua while `curl_easy_perform` runs, and LuaJIT cannot take a callback
-- from C that a compiled trace called ("bad callback"). The functions that reach libcurl are
-- therefore kept in the interpreter.
local curl = require("curl-sys")
local fs = require("fs")

local Http = {}

-- YouTube serves a media file in pieces: a request for more than about 10 MiB at once is cut off
-- or throttled, so a download asks for this much at a time with the `range` query parameter.
local CHUNK = 10 * 1024 * 1024
local TIMEOUT = 60

jit.off(curl.request)

---@param method "GET"|"POST"
---@param url string
---@param headers table<string, string>?
---@param body string?
---@return string? body
---@return string? err
local function send(method, url, headers, body)
	local res, err = curl.request({ url = url, method = method, headers = headers, body = body, timeout = TIMEOUT })
	if res == nil then return nil, err or "request failed" end
	if res.status < 200 or res.status >= 300 then return nil, "HTTP " .. res.status .. " from " .. url end
	return res.body
end
jit.off(send)

---@param url string
---@param headers table<string, string>?
---@return string? body
---@return string? err
function Http.get(url, headers)
	return send("GET", url, headers)
end

---@param url string
---@param body string
---@param headers table<string, string>?
---@return string? body
---@return string? err
function Http.post(url, body, headers)
	return send("POST", url, headers, body)
end

--- Downloads `url` to `path` in `CHUNK`-sized ranges. The bytes go to `<path>.part`, which is moved
--- into place only once every range has arrived. `total` is the size YouTube reported, when it
--- did; without one the download stops at the first short range.
---@param url string
---@param path string
---@param headers table<string, string>?
---@param total number?
---@param onProgress fun(received: number, total: number?)?
---@return boolean ok
---@return string? err
function Http.download(url, path, headers, total, onProgress)
	local part = path .. ".part"
	local file, openErr = io.open(part, "wb")
	if file == nil then return false, openErr end

	local received = 0
	local function fail(err)
		file:close()
		fs.delete(part)
		return false, err
	end

	while total == nil or received < total do
		local last = received + CHUNK - 1
		if total ~= nil and last >= total then last = total - 1 end
		local sep = url:find("?", 1, true) and "&" or "?"
		local body, err = send("GET", url .. sep .. "range=" .. received .. "-" .. last, headers)
		if body == nil then return fail(err) end
		if total ~= nil and #body ~= last - received + 1 then
			return fail(string.format("expected %d bytes at %d, got %d", last - received + 1, received, #body))
		end

		file:write(body)
		received = received + #body
		if onProgress ~= nil then onProgress(received, total) end
		if total == nil and #body < CHUNK then break end
	end

	file:close()
	if not fs.move(part, path) then
		fs.delete(part)
		return false, "could not move the download to " .. path
	end
	return true
end
jit.off(Http.download)

return Http
