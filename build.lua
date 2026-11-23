-- Vendors yt-dlp's challenge solver (https://github.com/yt-dlp/ejs) as `yt.ejs`: the lib script
-- (a JS parser and printer) and the core script that finds the signature and `n` functions in a
-- YouTube player and runs them. When YouTube changes its player, a new ejs release is the fix;
-- bump EJS_VERSION.
local build = require("lde-build")

local EJS_VERSION = "0.8.0"
local BASE = "https://github.com/yt-dlp/ejs/releases/download/" .. EJS_VERSION .. "/"

---@param name string
---@return string
local function script(name)
	local cached = build.cacheDir .. "/ejs-" .. EJS_VERSION .. "-" .. name
	if build:exists(cached) then return build:read(cached) end
	local code = build:fetch(BASE .. name)
	build:write(cached, code)
	return code
end

--- A long bracket whose level does not occur in the text, so the script is embedded verbatim.
---@param text string
---@return string
local function longString(text)
	local level = 0
	while text:find("]" .. string.rep("=", level) .. "]", 1, true) do level = level + 1 end
	local eq = string.rep("=", level)
	return "[" .. eq .. "[\n" .. text .. "]" .. eq .. "]"
end

build:write(
	"ejs.lua",
	"return {\n\tversion = " .. string.format("%q", EJS_VERSION) .. ",\n\tlib = " .. longString(
		script("yt.solver.lib.min.js")
	) .. ",\n\tcore = " .. longString(script("yt.solver.core.min.js")) .. "\n}\n"
)
