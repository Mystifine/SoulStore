local Config = {}

-- Routine messages only. Warnings about failed saves and loads always reach the output.
Config.DEBUG_MODE = false
Config.TRACE_BACK_MESSAGE = false

Config.LOAD_ATTEMPT_INTERVAL = 6 -- seconds between looks at a lock that a load is waiting for
Config.RETRY_INTERVAL = 2 -- seconds before a failed load or final save first retries
Config.MAX_RETRY_INTERVAL = 30 -- retries slow down after repeated failures, up to this. Set to 2 to keep them flat.

--[[
	I would suggest 30+. Roblox allows each key 4 MB of writes per minute, so at 30 seconds a save over 2 MB is
	throttled on some autosaves.
]]
Config.AUTO_SAVE_INTERVAL = 30

--[[
	How long a session can go without a confirmed write before it stops accepting changes. So this is how long players
	keep playing through an outage, which is why it is long. Keep it well above AUTO_SAVE_INTERVAL: normal saves don't
	retry, so this is how many can fail in a row. A lock this old, by Roblox's timestamp for the key, also takes less
	waiting for: see LOCK_TAKEOVER_TIME.
]]
Config.SESSION_LOCK_EXPIRY = 60 * 5

--[[
	How long a load watches a lock not change before taking it, on its own clock, so it holds even when servers disagree
	about the time. It starts over if the player leaves. A live session writes every AUTO_SAVE_INTERVAL, so a lock that
	does not change for three of those means its server crashed or cannot reach the data store. A lock already older than
	SESSION_LOCK_EXPIRY is watched for MAX_RETRY_INTERVAL x 1.5 instead, or for this long if that is shorter, which is
	still long enough for an owner that outlived an outage to land its final save. Set this to math.huge to only ever take
	locks that old.
]]
Config.LOCK_TAKEOVER_TIME = Config.AUTO_SAVE_INTERVAL * 3

Config.WRITER_WAIT_TIMEOUT = 10 -- how long a save waits behind one already running
Config.ACQUISITION_RECOVERY_TIMEOUT = 30 -- how long a cancelled load keeps trying to release a lock it may hold
Config.SHUTDOWN_TIMEOUT = 25 -- Roblox gives BindToClose 30 seconds

return Config
