-- The package's one entry point, for its three uses:
--
-- * `require("yt")`: the Lua API in `yt.core`.
-- * A shared library from `lde compile --shared`: loading it runs this chunk, which requires
--   `yt.capi` so its `---@export "C"` functions are registered.
-- * A program (`lde run`, or an executable from `lde compile`): the command line in `yt.cli`.
--
-- `require` passes the module name; the shared library runs this with no arguments and `arg[0]`
-- set to the module name; a program gets its command line.
local yt = require("yt.core")
require("yt.capi")

local first = ...
local loadedAsLibrary = first == "yt" or (first == nil and arg ~= nil and arg[0] == "yt")
if not loadedAsLibrary then os.exit(require("yt.cli")({ ... })) end

return yt
