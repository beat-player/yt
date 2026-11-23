-- The C API of `lde compile --shared`:
--
--   const char *yt_download(const char *input, const char *dir, const char *cache_dir);
--   const char *yt_info(const char *input, const char *cache_dir);
--   const char *yt_error(void);
--
-- `yt_download` saves the best audio of `input` (a URL or video id) in `dir` and returns its path;
-- `yt_info` returns the video's metadata and audio formats as JSON. Both return NULL on failure,
-- with the reason in `yt_error`. `cache_dir` may be NULL. A returned string stays valid until the
-- next call of the same function. Calls block, and must not be made from two threads at once.
local json = require("json")
local yt = require("yt.core")

local lastError = nil ---@type string?

-- One downloader per cache directory, so a player solved once stays solved across calls.
---@type table<string, yt.Downloader>
local downloaders = {}

---@param cacheDir string?
---@return yt.Downloader
local function downloader(cacheDir)
	local key = cacheDir or ""
	local dl = downloaders[key]
	if dl == nil then
		dl = yt.new({ cacheDir = cacheDir })
		downloaders[key] = dl
	end
	return dl
end

--- Runs `fn`, turning a failure (a nil result or a Lua error) into NULL and `yt_error`.
---@param fn fun(): string?, string?
---@return string?
local function guarded(fn)
	local ok, result, err = pcall(fn)
	if not ok then
		lastError = tostring(result)
		return nil
	end
	if result == nil then
		lastError = err or "unknown error"
		return nil
	end
	lastError = nil
	return result
end

---@export "C" yt_download fn(input: string, dir: string, cacheDir: string): string
local function download(input, dir, cacheDir)
	---@cast input string?
	---@cast dir string?
	---@cast cacheDir string?
	return guarded(function()
		if input == nil or dir == nil then return nil, "input and dir are required" end
		local dl = downloader(cacheDir)
		return dl:downloadAudio(input, dir)
	end)
end

---@export "C" yt_info fn(input: string, cacheDir: string): string
local function info(input, cacheDir)
	---@cast input string?
	---@cast cacheDir string?
	return guarded(function()
		if input == nil then return nil, "input is required" end
		local dl = downloader(cacheDir)
		local found, err = dl:info(input)
		if found == nil then return nil, err end
		return json.encode(found)
	end)
end

---@export "C" yt_error fn(): string
local function lastErrorMessage()
	return lastError
end

return { download = download, info = info, error = lastErrorMessage }
