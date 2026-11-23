-- YouTube's internal API (innertube): which clients to pretend to be, the visitor id it wants with
-- every request, and the `/player` request that lists a video's streams.
--
-- The clients mirror yt-dlp's `INNERTUBE_CLIENTS` (yt_dlp/extractor/youtube/_base.py). When YouTube
-- stops answering one of them, yt-dlp's next change to that table is the fix to copy here.
local json = require("json")
local Http = require("yt.http")

local Innertube = {}

local API = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
local BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " .. "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"

---@class yt.Client
---@field key string # yt-dlp's name for it
---@field id number # X-YouTube-Client-Name
---@field context table # `context.client` of a request
---@field js boolean # Its stream URLs carry challenges only the player's JavaScript can solve

-- Tried in this order. visionos needs no player JavaScript and no PO token; tv_samsung needs the
-- player for its `n` and signature challenges, also without a PO token.
---@type yt.Client[]
Innertube.clients = {
	{
		key = "visionos",
		id = 101,
		js = false,
		context = {
			clientName = "VISIONOS",
			clientVersion = "1.02",
			deviceMake = "Apple",
			deviceModel = "RealityDevice17,1",
			userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 " .. "(KHTML, like Gecko) Version/26.0 Safari/605.1.15",
			osName = "visionOS",
			osVersion = "26.5.23O471",
			hl = "en"
		}
	},
	{
		key = "tv_samsung",
		id = 7,
		js = true,
		context = {
			clientName = "TVHTML5",
			clientVersion = "5.20260707",
			deviceMake = "Samsung",
			deviceModel = "UKS9800",
			userAgent = "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 " .. "(KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
			osName = "Tizen",
			osVersion = "2.4.0",
			hl = "en"
		}
	}
}

---@param s string
---@return string
local function urlDecode(s)
	return (s:gsub("%+", " "):gsub("%%(%x%x)", hex -> string.char(tonumber(hex, 16) --[[@as number]] )))
end
Innertube.urlDecode = urlDecode

--- The visitor id YouTube expects in `X-Goog-Visitor-Id`; without it every client is asked to sign
--- in. `sw.js_data` hands one out in a couple of kilobytes, where the watch page is over a megabyte.
---@return string? visitorData
---@return string? err
function Innertube.visitorData()
	local body, err = Http.get("https://www.youtube.com/sw.js_data", { ["User-Agent"] = BROWSER_UA })
	if body == nil then return nil, err end

	-- The JSON is behind an anti-XSSI prefix: `)]}'` and a newline.
	local ok, root = pcall(json.decode, ((body:gsub("^%)%]}'\n?", ""))))
	if not ok then return nil, "sw.js_data is not JSON: " .. tostring(root) end
	local data = root:unpack()
	local value = data[1] and data[1][3] and data[1][3][1] and data[1][3][1][1] and data[1][3][1][1][14]
	if type(value) ~= "string" then return nil, "sw.js_data has no visitor data" end
	return urlDecode(value)
end

---@class yt.ApiFormat
---@field itag number
---@field mimeType string?
---@field url string?
---@field signatureCipher string?
---@field bitrate number?
---@field contentLength string?
---@field isDrc boolean?

---@class yt.PlayerResponse
---@field playabilityStatus { status: string?, reason: string? }?
---@field streamingData { adaptiveFormats: yt.ApiFormat[]? }?
---@field videoDetails { title: string?, author: string?, lengthSeconds: string? }?
---@field adPlacements any[]? # Ad shapes are walked defensively in `adWait`
---@field adSlots any[]?

--- Asks for a video's player response as `client`.
---@param client yt.Client
---@param videoId string
---@param visitorData string
---@param sts number? # The player's signature timestamp; needed by a client whose URLs are signed
---@return yt.PlayerResponse? response
---@return string? err
function Innertube.player(client, videoId, visitorData, sts)
	local request = { context = { client = client.context }, videoId = videoId, contentCheckOk = true, racyCheckOk = true }
	if sts ~= nil then
		request.playbackContext = {
			contentPlaybackContext = { html5Preference = "HTML5_PREF_WANTS", signatureTimestamp = sts }
		}
	end

	local body, err = Http.post(API, json.encode(request), {
		["Content-Type"] = "application/json",
		["User-Agent"] = client.context.userAgent,
		["X-YouTube-Client-Name"] = tostring(client.id),
		["X-YouTube-Client-Version"] = client.context.clientVersion,
		["X-Goog-Visitor-Id"] = visitorData,
		["Origin"] = "https://www.youtube.com"
	})
	if body == nil then return nil, err end

	local ok, root = pcall(json.decode, body)
	if not ok then return nil, client.key .. " player response is not JSON" end
	return root:unpack()
end

--- `value[k1][k2]...`, or nil as soon as a step is not a table.
---@param value any
---@param ... string
---@return any
local function dig(value, ...)
	for i = 1, select("#", ...) do
		if type(value) ~= "table" then return nil end
		value = value[select(i, ...)]
	end
	return value
end

--- How long YouTube holds back a video's streams for the ads it would play first: until the first
--- skippable moment, or the end, of each pre-roll. A stream fetched sooner answers 403. Follows
--- yt-dlp's `_get_available_at_timestamp`.
---@param response yt.PlayerResponse
---@return number seconds
function Innertube.adWait(response)
	local renderers = {}
	for _, placement in ipairs(response.adPlacements or {}) do
		if dig(placement, "adPlacementRenderer", "config", "adPlacementConfig", "kind") == "AD_PLACEMENT_KIND_START" then
			renderers[#renderers + 1] = dig(placement, "adPlacementRenderer", "renderer")
		end
	end
	for _, slot in ipairs(response.adSlots or {}) do
		if dig(slot, "adSlotRenderer", "adSlotMetadata", "triggerEvent") == "SLOT_TRIGGER_EVENT_BEFORE_CONTENT" then
			local content = dig(
				slot,
				"adSlotRenderer",
				"fulfillmentContent",
				"fulfilledLayout",
				"playerBytesAdLayoutRenderer",
				"renderingContent"
			)
			renderers[#renderers + 1] = content
			local sequential = dig(content, "playerBytesSequentialLayoutRenderer", "sequentialLayouts") or {}
			for _, inner in ipairs(sequential --[[@as table]] ) do
				renderers[#renderers + 1] = dig(inner, "playerBytesAdLayoutRenderer", "renderingContent")
			end
		end
	end

	local wait = 0
	for _, renderer in ipairs(renderers) do
		local ad = dig(renderer, "instreamVideoAdRenderer")
		if type(ad) == "table" then
			local skip = tonumber(ad.skipOffsetMilliseconds)
			local length
			for value in ("&" .. tostring(ad.playerVars or "")):gmatch("&length_seconds=(%d+)") do length = tonumber(value) end
			wait = wait + (skip and skip / 1000 or length or 0)
		end
	end
	return math.ceil(wait)
end

return Innertube
