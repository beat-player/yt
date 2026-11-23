-- yt <url or id> [output directory]
-- Downloads the best audio stream of a video as `<dir>/<id>.<container>` and prints its path.
local path = require("path")
local yt = require("yt.core")

---@param args string[]
---@return integer status
return function(args)
	local input, dir = args[1], args[2] or "."
	if input == nil or input == "-h" or input == "--help" then
		io.stderr:write("usage: yt <url or id> [output directory]\n")
		return input == nil and 2 or 0
	end

	local home = os.getenv("HOME") or os.getenv("USERPROFILE")
	local dl = yt.new({ cacheDir = home and path.join(home, ".cache", "yt") or nil })
	local out, err, info, format = dl:downloadAudio(input, dir, nil, function(received, total)
		io.stderr:write(string.format("\r%d / %s bytes", received, total and tostring(total) or "?"))
	end)
	dl:close()

	if out == nil then
		io.stderr:write("\nyt: " .. tostring(err) .. "\n")
		return 1
	end
	---@cast info yt.Info
	---@cast format yt.Format
	io.stderr:write(
		string.format(
			"\n%s - %s [%s, itag %d, %s]\n",
			tostring(info.author),
			tostring(info.title),
			info.client,
			format.itag,
			format.codec
		)
	)
	print(out)
	return 0
end
