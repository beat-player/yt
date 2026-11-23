-- Finds and downloads the audio streams of a YouTube video. This is what `require("yt")` returns.
--
--   local dl = yt.new({ cacheDir = "..." })
--   local info = assert(dl:info("https://www.youtube.com/watch?v=jNQXAC9IVRw"))
--   local format = yt.bestAudio(info)
--   assert(dl:download(format, "zoo." .. format.container, function(received, total) end))
--
-- Every call blocks on the network (and `info` on QuickJS, the first time it meets a player), so a
-- UI runs it on a thread. Stream URLs expire after a few hours: download soon after `info`.
local Http = require("yt.http")
local Innertube = require("yt.innertube")
local Solver = require("yt.solver")
local ffi = require("ffi")

if jit.os == "Windows" then
	ffi.cdef("void Sleep(uint32_t ms);")
else
	ffi.cdef("unsigned int sleep(unsigned int seconds);")
end

---@param seconds number
local function sleep(seconds)
	if jit.os == "Windows" then
		ffi.C.Sleep(seconds * 1000)
	else
		ffi.C.sleep(seconds)
	end
end

local yt = {}

---@class yt.Format
---@field itag number
---@field mimeType string # e.g. `audio/webm; codecs="opus"`
---@field container "webm"|"m4a"|string
---@field codec string # e.g. `opus`, `mp4a.40.2`
---@field bitrate number # Bits per second
---@field size number? # Bytes
---@field drc boolean # Dynamic range compressed: a louder, flattened copy of another format
---@field url string # Ready to fetch: its challenges are already solved
---@field userAgent string # The client's; the stream is fetched as the client that asked for it
---@field availableAt number # Unix time YouTube serves it from: after the pre-roll ads it would play

---@class yt.Info
---@field id string
---@field title string?
---@field author string?
---@field duration number? # Seconds
---@field client string # Which innertube client the formats came from
---@field formats yt.Format[] # Audio only

---@class yt.Options
---@field cacheDir string? # Where solved players are kept between runs; memory only without one

---@class yt.Downloader
---@field solver yt.Solver
---@field visitor string?
local Downloader = {}
Downloader.__index = Downloader

---@param opts yt.Options?
---@return yt.Downloader
function yt.new(opts)
	opts = opts or {}
	return setmetatable({ solver = Solver.new(opts.cacheDir), visitor = nil }, Downloader)
end

--- The 11-character id in a watch, share, shorts, embed or music URL, or an id on its own.
---@param input string
---@return string?
function yt.videoId(input)
	local id = input:match("^[%w_-]+$")
	if id ~= nil and #id == 11 then return id end
	---@type string[]
	local patterns = {
		"[?&]v=([%w_-]+)",
		"youtu%.be/([%w_-]+)",
		"/shorts/([%w_-]+)",
		"/embed/([%w_-]+)",
		"/live/([%w_-]+)"
	}
	for _, pattern in ipairs(patterns) do
		local match = input:match(pattern) --[[@as string?]]
		if match ~= nil and #match == 11 then return match end
	end
	return nil
end

---@param query string
---@return table<string, string>
local function parseQuery(query)
	local out = {}
	for key, value in query:gmatch("([^&=]+)=([^&]*)") do
		out[Innertube.urlDecode(key --[[@as string]] )] = Innertube.urlDecode(value --[[@as string]] )
	end
	return out
end

---@param s string
---@return string
local function urlEncode(s)
	return (s:gsub("[^%w%-%._~]", c -> string.format("%%%02X", c:byte())))
end

---@class yt.RawFormat
---@field format yt.Format
---@field n string? # The `n` challenge in its URL
---@field s string? # The signature challenge, for a ciphered format
---@field sp string? # The query parameter the solved signature goes in

--- The audio formats of a player response, with their challenges still in them.
---@param response yt.PlayerResponse
---@param client yt.Client
---@return yt.RawFormat[]
local function audioFormats(response, client)
	---@type yt.RawFormat[]
	local out = {}
	local streaming = response.streamingData
	for _, f in ipairs(streaming and streaming.adaptiveFormats or {}) do
		local mime = f.mimeType or ""
		local url, s, sp = f.url, nil, nil
		if url == nil and f.signatureCipher ~= nil then
			local cipher = parseQuery(f.signatureCipher)
			url, s, sp = cipher.url, cipher.s, cipher.sp or "signature"
		end
		if mime:find("^audio/") and url ~= nil then
			local kind = mime:match("^audio/(%w+)") or ""
			out[#out + 1] = {
				n = parseQuery(url:match("%?(.*)$") or "").n,
				s = s,
				sp = sp,
				format = {
					itag = f.itag,
					mimeType = mime,
					container = kind == "mp4" and "m4a" or kind,
					codec = mime:match('codecs="([^"]+)"') or "",
					bitrate = f.bitrate or 0,
					size = tonumber(f.contentLength),
					drc = f.isDrc == true,
					url = url,
					userAgent = client.context.userAgent,
					availableAt = 0
				}
			}
		end
	end
	return out
end

--- Solves every challenge in `raws` in one pass and writes the answers into their URLs.
---@param solver yt.Solver
---@param player yt.Player
---@param raws yt.RawFormat[]
---@return boolean ok
---@return string? err
local function solveFormats(solver, player, raws)
	---@type yt.Challenges
	local challenges = { n = {}, sig = {} }
	local seen = {}
	for _, raw in ipairs(raws) do
		if raw.n ~= nil and not seen["n" .. raw.n] then
			seen["n" .. raw.n] = true
			challenges.n[#challenges.n + 1] = raw.n
		end
		if raw.s ~= nil and not seen["s" .. raw.s] then
			seen["s" .. raw.s] = true
			challenges.sig[#challenges.sig + 1] = raw.s
		end
	end

	local answers, err = solver:solve(player, challenges)
	if answers == nil then return false, err end

	for _, raw in ipairs(raws) do
		local format = raw.format
		if raw.n ~= nil then
			local solved = answers.n and answers.n[raw.n]
			if solved == nil then return false, "no answer for n challenge " .. raw.n end
			format.url = format.url:gsub("([?&]n=)[^&]*", prefix -> prefix .. urlEncode(solved), 1)
		end
		if raw.s ~= nil then
			local solved = answers.sig and answers.sig[raw.s]
			if solved == nil then return false, "no answer for signature challenge" end
			format.url = format.url .. "&" .. raw.sp .. "=" .. urlEncode(solved)
		end
	end
	return true
end

--- A video's metadata and audio formats, trying each client in `Innertube.clients` until one
--- answers with formats.
---@param input string # A URL or a video id
---@return yt.Info? info
---@return string? err
function Downloader:info(input)
	local id = yt.videoId(input)
	if id == nil then return nil, "not a YouTube video: " .. input end

	if self.visitor == nil then
		local visitor, err = Innertube.visitorData()
		if visitor == nil then return nil, err end
		self.visitor = visitor
	end

	local failures = {}
	for _, client in ipairs(Innertube.clients) do
		local player, err
		if client.js then player, err = self.solver:player() end

		---@type yt.PlayerResponse?
		local response
		if not client.js or player ~= nil then
			response, err = Innertube.player(client,  id,  self.visitor --[[@as string]],  player and player.sts )
		end

		if response ~= nil then
			local playability = response.playabilityStatus or {}
			if playability.status ~= "OK" then
				err = tostring(playability.status) .. ": " .. tostring(playability.reason)
			else
				local raws = audioFormats(response, client)
				local ciphered = false
				for _, raw in ipairs(raws) do ciphered = ciphered or raw.s ~= nil or raw.n ~= nil end

				local ok = true
				if ciphered and player == nil then
					ok, err = false, "challenged URLs from a client without a player"
				elseif ciphered then
					ok, err = solveFormats(self.solver,  player --[[@as yt.Player]],  raws )
				elseif #raws == 0 then
					ok, err = false, "no audio formats"
				end

				if ok then
					local details = response.videoDetails or {}
					local formats = {}
					local availableAt = os.time() + 1 + Innertube.adWait(response)
					for i, raw in ipairs(raws) do
						raw.format.availableAt = availableAt
						formats[i] = raw.format
					end
					return {
						id = id,
						title = details.title,
						author = details.author,
						duration = tonumber(details.lengthSeconds),
						client = client.key,
						formats = formats
					}
				end
			end
		end
		failures[#failures + 1] = client.key .. ": " .. tostring(err)
	end

	return nil, table.concat(failures, "; ")
end

--- The format with the highest bitrate, skipping range-compressed copies. `container` limits it to
--- one container ("webm" for Opus, "m4a" for AAC) when one of that kind exists.
---@param info yt.Info
---@param container string?
---@return yt.Format?
function yt.bestAudio(info, container)
	local best, bestMatches
	for _, format in ipairs(info.formats) do
		if not format.drc then
			local matches = container == nil or format.container == container
			if best == nil or (matches and not bestMatches) or (matches == bestMatches and format.bitrate > best.bitrate) then
				best, bestMatches = format, matches
			end
		end
	end
	return best
end

--- Downloads `format` to `path`. Nothing is left at `path` unless the whole stream arrived. Waits
--- first when the format is not available yet.
---@param format yt.Format
---@param path string
---@param onProgress fun(received: number, total: number?)?
---@return boolean ok
---@return string? err
function Downloader:download(format, path, onProgress)
	local wait = format.availableAt - os.time()
	if wait > 0 then sleep(wait) end
	return Http.download(format.url, path, { ["User-Agent"] = format.userAgent }, format.size, onProgress)
end

--- `info`, `bestAudio` and `download` in one: the best audio of `input` saved as
--- `<dir>/<id>.<container>`.
---@param input string # A URL or a video id
---@param dir string
---@param container string? # Preferred container, see `yt.bestAudio`
---@param onProgress fun(received: number, total: number?)?
---@return string? path
---@return string? err
---@return yt.Info? info
---@return yt.Format? format
function Downloader:downloadAudio(input, dir, container, onProgress)
	local info, err = self:info(input)
	if info == nil then return nil, err end
	local format = yt.bestAudio(info, container)
	if format == nil then return nil, "no audio format", info end

	local out = dir .. "/" .. info.id .. "." .. format.container
	local ok, downloadErr = self:download(format, out, onProgress)
	if not ok then return nil, downloadErr, info, format end
	return out, nil, info, format
end

function Downloader:close()
	self.solver:close()
end

return yt
