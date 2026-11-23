-- What can go wrong without the network: reading a video id out of the URL forms people paste,
-- how long the pre-roll ads hold a stream back (fetched sooner, it answers 403), and which audio
-- format is picked.
local test = require("lde-test")
local yt = require("yt")
local Innertube = require("yt.innertube")

test.it("finds the video id in the URL forms YouTube hands out", function()
	for _, input in ipairs({
		"dQw4w9WgXcQ",
		"https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		"https://www.youtube.com/watch?feature=share&v=dQw4w9WgXcQ&t=42",
		"https://youtu.be/dQw4w9WgXcQ?si=abc",
		"https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RD",
		"https://www.youtube.com/shorts/dQw4w9WgXcQ",
		"https://www.youtube.com/embed/dQw4w9WgXcQ"
	}) do
		test.equal(yt.videoId(input), "dQw4w9WgXcQ")
	end
	test.equal(yt.videoId("https://example.com/"), nil)
end)

test.it("waits until a pre-roll can be skipped, or for its whole length", function()
	local skippable = {
		adPlacements = {
			{
				adPlacementRenderer = {
					config = { adPlacementConfig = { kind = "AD_PLACEMENT_KIND_START" } },
					renderer = { instreamVideoAdRenderer = { skipOffsetMilliseconds = 5000, playerVars = "length_seconds=15&x=1" } }
				}
			}
		}
	}
	test.equal(Innertube.adWait(skippable), 5)

	local unskippable = {
		adSlots = {
			{
				adSlotRenderer = {
					adSlotMetadata = { triggerEvent = "SLOT_TRIGGER_EVENT_BEFORE_CONTENT" },
					fulfillmentContent = {
						fulfilledLayout = {
							playerBytesAdLayoutRenderer = {
								renderingContent = { instreamVideoAdRenderer = { playerVars = "a=1&length_seconds=15" } }
							}
						}
					}
				}
			}
		}
	}
	test.equal(Innertube.adWait(unskippable), 15)

	local midroll = {
		adPlacements = {
			{
				adPlacementRenderer = {
					config = { adPlacementConfig = { kind = "AD_PLACEMENT_KIND_MILLISECONDS" } },
					renderer = { instreamVideoAdRenderer = { skipOffsetMilliseconds = 5000 } }
				}
			}
		}
	}
	test.equal(Innertube.adWait(midroll), 0)
end)

test.it("picks the highest bitrate, skipping range-compressed copies and preferring a container", function()
	---@param itag number
	---@param container string
	---@param bitrate number
	---@param drc boolean
	---@return yt.Format
	local function format(itag, container, bitrate, drc)
		return {
			itag = itag,
			mimeType = "",
			container = container,
			codec = "",
			bitrate = bitrate,
			drc = drc,
			url = "",
			userAgent = "",
			availableAt = 0
		}
	end
	local info = {
		id = "dQw4w9WgXcQ",
		client = "test",
		formats = {
			format(251, "webm", 140000, true),
			format(251, "webm", 130000, false),
			format(140, "m4a", 135000, false),
			format(250, "webm", 70000, false)
		}
	}

	local best = yt.bestAudio(info) --[[@as yt.Format]]
	test.equal(best.itag, 140)
	local opus = yt.bestAudio(info, "webm") --[[@as yt.Format]]
	test.equal(opus.itag, 251)
	test.equal(opus.drc, false)
end)
