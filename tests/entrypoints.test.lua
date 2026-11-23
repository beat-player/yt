-- The package's three entry points: the Lua API, the command line of an `lde compile`d executable,
-- and the C API of an `lde compile --shared` library driven from C. These need the network, `lde`
-- on PATH and a C compiler.
--
-- Skipped on GitHub Actions: YouTube answers its runners' datacenter addresses with a bot check
-- ("Sign in to confirm you're not a bot") for every client yt can use without signing in.
local test = require("lde-test")
local fs = require("fs")
local path = require("path")
local process = require("process")
local yt = require("yt")

-- "Me at the zoo": 19 seconds, no ads, a few hundred kilobytes of audio.
local VIDEO = "jNQXAC9IVRw"

local isWindows = jit.os == "Windows"
local root = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]tests[/\\]") or "."
-- Not under target/: `lde compile` bundles every native library it finds there, which would put
-- one test's build inside the next.
local tmp = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
local out = path.join(tmp, "yt-entrypoints")
fs.mkdirAll(out)

local onGithub = os.getenv("GITHUB_ACTIONS") == "true"

---@param name string
---@param args string[]
---@return number? code
---@return string output
local function run(name, args)
	local code, stdout, stderr = process.exec(name, args, { cwd = root })
	return code, (stdout or "") .. (stderr or "")
end

--- The compiler lde builds with: SEA_CC, then the toolchain lde installs on Windows, then cc.
---@return string
local function compiler()
	local override = os.getenv("SEA_CC") or os.getenv("CC")
	if override ~= nil and override ~= "" then return override end
	if isWindows then
		local home = os.getenv("USERPROFILE") or ""
		for _, candidate in ipairs({ "clang.exe", "gcc.exe" }) do
			local full = path.join(home, ".lde", "mingw", "bin", candidate)
			if fs.exists(full) then return full end
		end
		return "gcc"
	end
	return "cc"
end

---@param file string
---@return number
local function size(file)
	local content = fs.read(file)
	return content and #content or 0
end

--- The executable `lde compile` builds.
---@return string
local function cliExecutable()
	local exe = path.join(out, isWindows and "yt.exe" or "yt")
	local code, output = run("lde", { "compile", "--outfile", exe })
	test.equal(code, 0, output)
	return exe
end

--- tests/c/download.c, built against the library `lde compile --shared` builds.
---@return string exe
---@return string lib
local function cProgram()
	local ext = isWindows and "dll" or (jit.os == "OSX" and "dylib" or "so")
	local lib = path.join(out, "libyt." .. ext)
	local code, output = run("lde", { "compile", "--shared", "--outfile", lib })
	test.equal(code, 0, output)

	local exe = path.join(out, isWindows and "download.exe" or "download")
	local args = { path.join(root, "tests", "c", "download.c"), "-o", exe }
	if jit.os == "Linux" then args[#args + 1] = "-ldl" end
	code, output = run(compiler(), args)
	test.equal(code, 0, output)
	return exe, lib
end

test.skipIf(onGithub)("downloads through the Lua API", function()
	local dl = yt.new()
	local info, err = dl:info("https://www.youtube.com/watch?v=" .. VIDEO)
	test.truthy(info, tostring(err))
	test.equal(info.id, VIDEO)
	test.greater(#info.formats, 0)

	local file, downloadErr, _, format = dl:downloadAudio(VIDEO, out, "webm")
	dl:close()
	test.truthy(file, tostring(downloadErr))
	---@cast file string
	---@cast format yt.Format
	test.equal(format.container, "webm")
	test.equal(size(file), format.size)
end)

test.skipIf(onGithub)("downloads through a compiled command line", function()
	local exe = cliExecutable()
	local dir = path.join(out, "cli")
	fs.mkdirAll(dir)
	local code, output = run(exe, { VIDEO, dir })
	test.equal(code, 0, output)
	local file = output:match("([^\r\n]*" .. VIDEO .. "%.%w+)") --[[@as string?]]
	test.truthy(file and size(file) > 0, "the printed path holds the audio: " .. output)

	code = run(exe, {})
	test.equal(code, 2)
end)

test.skipIf(onGithub)("downloads through the C API of a shared library", function()
	local exe, lib = cProgram()
	local dir = path.join(out, "c")
	fs.mkdirAll(dir)
	local code, output = run(exe, { lib, VIDEO, dir })
	test.equal(code, 0, output)
	test.includes(output, '"id":"' .. VIDEO .. '"', "yt_info returned the video's JSON")
	local file = output:match("([^\r\n]*" .. VIDEO .. "%.%w+)%s*$") --[[@as string?]]
	test.truthy(file and size(file) > 0, "yt_download returned the audio's path: " .. output)
end)
