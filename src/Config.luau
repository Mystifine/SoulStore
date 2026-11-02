local Config = {}

-- Routine messages only. Warnings about failed saves and loads always reach the output.
Config.DEBUG_MODE = true
Config.TRACE_BACK_MESSAGE = false

Config.LOAD_ATTEMPT_INTERVAL = 6 -- seconds between looks at a lock that a load is waiting for
Config.RETRY_INTERVAL = 2 -- seconds before a failed load or final save first retries
Config.MAX_RETRY_INTERVAL = 30 -- failed loads slow down after repeated failures, up to this
Config.MAX_FINAL_SAVE_RETRY_INTERVAL = 10 -- final saves stop slowing down here, to reach the store before a load

--[[
	I would suggest 30+. Roblox allows each key 4 MB of writes per minute, so at 30 seconds a save over 2 MB is
	throttled on some autosaves.
]]
Config.AUTO_SAVE_INTERVAL = 30

--[[
	How long a lock can go without a write before another session may take it. A live session writes every
	AUTO_SAVE_INTERVAL, so this much silence means its server crashed or cannot reach the data store. This is the one
	setting for session locks: shorter means faster recovery from a crash, and more chance of taking over a session that
	is only slow.
]]
Config.SESSION_EXPIRY = 120

--[[
	A load that finds a lock past the expiry waits this long and takes it only if it has not changed. After an outage
	every lock looks expired, and its owner may be about to land its final save, so this is longer than that save's
	slowest retry.
]]
Config.TAKEOVER_DELAY = Config.MAX_FINAL_SAVE_RETRY_INTERVAL * 1.5

Config.HUNG_SAVE_TIME = 60 -- a save running this long no longer holds up the next one
Config.WRITER_WAIT_TIMEOUT = 10 -- how long a save waits behind one already running
Config.ACQUISITION_RECOVERY_TIMEOUT = 30 -- how long a cancelled load keeps trying to release a lock it may hold

return Config
