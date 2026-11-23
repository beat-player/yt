-- Solves the `n` and signature challenges in stream URLs with yt-dlp's ejs scripts on QuickJS.
--
-- ejs parses the whole player (about 3 MB) to find the two functions, which takes QuickJS a few
-- seconds; what it hands back alongside the answers is the player cut down to those functions
-- ("preprocessed"), which solves in a fraction of a second. A player is therefore kept in that
-- form, in memory and in `cacheDir` when there is one, keyed by its id. YouTube ships a new player
-- every few days to weeks.
local fs = require("fs")
local json = require("json")
local path = require("path")
local js = require("js")
local ejs = require("yt.ejs")
local Http = require("yt.http")

---@class yt.Player
---@field id string
---@field sts number # Signature timestamp: tells the API which player the URLs are for
---@field code string? # The full player, until it has been preprocessed once
---@field preprocessed string?

---@class yt.Solver
---@field cacheDir string?
---@field players table<string, yt.Player>
---@field ctx js.Context?
local Solver = {}
Solver.__index = Solver

---@param cacheDir string?
---@return yt.Solver
function Solver.new(cacheDir)
	return setmetatable({ cacheDir = cacheDir, players = {}, ctx = nil }, Solver)
end

---@param self yt.Solver
---@param id string
---@return string?
function Solver:cachePath(id)
	if self.cacheDir == nil then return nil end
	return path.join(self.cacheDir, "player-" .. id .. "-ejs-" .. ejs.version .. ".js")
end

--- The id of the player youtube.com currently serves, from the small iframe API script.
---@return string? id
---@return string? err
local function currentPlayerId()
	local body, err = Http.get("https://www.youtube.com/iframe_api")
	if body == nil then return nil, err end
	local id = body:match("player\\/(%x+)\\/")
	if id == nil then return nil, "no player id in iframe_api" end
	return id
end

--- The current player: from memory, the cache directory, or youtube.com.
---@param self yt.Solver
---@return yt.Player? player
---@return string? err
function Solver:player()
	local id, err = currentPlayerId()
	if id == nil then return nil, err end
	if self.players[id] ~= nil then return self.players[id] end

	local cached = self:cachePath(id)
	local stored = cached ~= nil and fs.read(cached) or nil
	if stored ~= nil then
		-- First line: the signature timestamp; the rest: the preprocessed player.
		local sts, preprocessed = stored:match("^(%d+)\n(.*)$")
		if sts ~= nil then
			self.players[id] = {
				id = id, --[[@as number]]
				sts = tonumber(sts),
				preprocessed = preprocessed
			}
			return self.players[id]
		end
	end

	local code, fetchErr = Http.get("https://www.youtube.com/s/player/" .. id .. "/player_ias.vflset/en_US/base.js")
	if code == nil then return nil, fetchErr end
	local sts = code:match("signatureTimestamp%s*:%s*(%d%d%d%d%d)") or code:match("sts%s*:%s*(%d%d%d%d%d)")
	if sts == nil then return nil, "no signature timestamp in player " .. id end

	self.players[id] = {
		id = id, --[[@as number]]
		sts = tonumber(sts),
		code = code
	}
	return self.players[id]
end

---@param self yt.Solver
---@return js.Context
function Solver:context()
	if self.ctx ~= nil then
		return self.ctx --[[@as js.Context]]
	end
	local ctx = js.new()
	local _, err = ctx:eval(ejs.lib .. "\nObject.assign(globalThis, lib);\n" .. ejs.core, "ejs.js")
	if err ~= nil then
		ctx:close()
		error("ejs failed to load: " .. err, 0)
	end
	self.ctx = ctx
	return ctx
end

---@class yt.Challenges
---@field n string[]
---@field sig string[]

---@class yt.Answers
---@field n table<string, string>?
---@field sig table<string, string>?

--- Solves challenges against `player`, preprocessing it on first use.
---@param player yt.Player
---@param challenges yt.Challenges
---@return yt.Answers? answers # Challenge to answer, per type
---@return string? err
function Solver:solve(player, challenges)
	---@type string[]
	local types = {}
	local requests = {}
	for _, kind in ipairs({ "n", "sig" }) do
		local list = challenges[kind] --[[@as string[] ]]
		if #list > 0 then
			types[#types + 1] = kind
			requests[#requests + 1] = { type = kind, challenges = list }
		end
	end
	if #requests == 0 then return {} end

	local input
	if player.preprocessed ~= nil then
		input = { type = "preprocessed", preprocessed_player = player.preprocessed, requests = requests }
	else
		input = { type = "player", player = player.code, requests = requests, output_preprocessed = true }
	end

	local okCtx, ctx = pcall(self.context, self)
	if not okCtx then return nil, ctx end
	local out, err = ctx:eval("JSON.stringify(jsc(" .. json.encode(input) .. "))", "solve.js")
	if out == nil then return nil, err end

	local root = json.decode(out)
	if root:get("type"):val() == "error" then
		local message = root:get("error", false)
		return nil, "ejs: " .. tostring(message and message:val())
	end

	local preprocessed = root:get("preprocessed_player", false)
	if preprocessed and player.preprocessed == nil then
		player.preprocessed = preprocessed:val()
		player.code = nil
		local cached = self:cachePath(player.id)
		if cached ~= nil then
			fs.mkdirAll(self.cacheDir --[[@as string]] )
			fs.write(cached, player.sts .. "\n" .. player.preprocessed)
		end
	end

	local answers = {}
	local responses = root:get("responses"):unpack()
	for i, kind in ipairs(types) do
		local response = responses[i]
		if response == nil or response.type ~= "result" then
			return nil, "ejs could not solve " .. kind .. ": " .. tostring(response and response.error)
		end
		answers[kind] = response.data
	end
	return answers
end

---@param self yt.Solver
function Solver:close()
	if self.ctx ~= nil then
		self.ctx:close()
		self.ctx = nil
	end
end

return Solver
