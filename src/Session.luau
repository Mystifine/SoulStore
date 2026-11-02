--[[
	The session flow: claiming a record, normal saves, and final saves.

	A normal save makes one attempt and reports the result. The next autosave carries newer data anyway.
	A final save retries until it lands, is refused by another session, or hits an error retrying cannot fix.
	Every save writes only while the stored record still names this session's token.

	Pulling -> Active -> Ending -> Ended
	Pulling -> Cancelled
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)
local DataValidator = require(script.Parent.DataValidator)
local DeepCopyUtil = require(script.Parent.DeepCopyUtil)
local Logger = require(script.Parent.Logger)
local SessionCache = require(script.Parent.SessionCache)
local Types = require(script.Parent.Types)

type Soul = Types.Soul

local SESSION_STATES = {
	Pulling = "Pulling",
	Active = "Active",
	Ending = "Ending",
	Ended = "Ended",
	Cancelled = "Cancelled",
}

-- LoadState and SaveState are kept for existing callers. SessionState is the one that decides anything.
local SAVE_STATES = {
	Saving = "Saving",
	SessionEnding = "SessionEnding",
	Idle = "Idle",
}

local LOAD_STATES = {
	Idle = "Idle",
	Loading = "Loading",
	Loaded = "Loaded",
}

-- Errors that retrying cannot fix: a bad key or value, or a data store this server cannot reach at all.
local NON_RETRYABLE_ERRORS = {}
for _, code in ipairs({ 101, 102, 103, 104, 105, 106, 107, 401, 402, 403, 509, 511, 512, 513 }) do
	NON_RETRYABLE_ERRORS[code] = true
end

local MAX_USER_IDS = 4 -- Roblox's limit per key. Going over it would fail every save with error 512.

local Session = {}
Session.States = SESSION_STATES
Session.SaveStates = SAVE_STATES
Session.LoadStates = LOAD_STATES
Session.isShuttingDown = false

----------------------------------------------------------------------------------------------------------------- Checks

function Session.playerExists(player: Player?): boolean
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

function Session.isSettled(soul: Soul): boolean
	return soul.SessionState == SESSION_STATES.Ended or soul.SessionState == SESSION_STATES.Cancelled
end

-- Gameplay may only touch a session that is active. An outage does not end one: its next save lands once the store is
-- back, or finds out that another session took the record. Leaving ends the session through PlayerRemoving, so this
-- does not check the player: leave handlers and the final save hook can still read and write, and what they write is
-- in the final save.
function Session.isUsable(soul: Soul): boolean
	return soul.SessionState == SESSION_STATES.Active
end

---------------------------------------------------------------------------------------------------------------- Helpers

function Session.getDatastore(datastoreId: string, scope: string?): DataStore
	return DataStoreService:GetDataStore(datastoreId, scope or SessionCache.DEFAULT_SCOPE)
end

--[[
	Gets new meta data

	@param sessionToken : string? - The token of the session that owns it. Without one the data is unlocked.
	@return MetaData - The meta data
]]
function Session.getMetaData(sessionToken: string?): Types.SoulMetaData
	return {
		Locked = sessionToken ~= nil,
		SaveId = 0,
		LastUpdate = os.time(),
		SessionId = sessionToken or "",
	}
end

local function describe(soul: Soul): string
	return string.format("'%s' (%d)", soul.Player.Name, soul.UserId)
end

local function isRetryable(message: any): boolean
	local text = tostring(message)
	-- An unpublished place, or Studio without API access: nothing changes until the developer changes it
	if
		string.find(text, "must publish", 1, true) or (RunService:IsStudio() and string.find(text, "HTTP 403", 1, true))
	then
		return false
	end
	local code = tonumber(string.match(text, "^%s*(%d%d%d):"))
	return not (code and NON_RETRYABLE_ERRORS[code])
end

local function nextRetryDelay(delay: number, longest: number): number
	-- Shutdown only has about 30 seconds, so retries do not slow down much
	return math.min(delay * 1.5, if Session.isShuttingDown then Config.RETRY_INTERVAL * 3 else longest)
end

-- Waits about this long. The jitter keeps players and servers from all retrying at the same moment.
local function waitUnless(duration: number, shouldStop: () -> boolean)
	local deadline = os.clock() + duration * (0.8 + math.random() * 0.4)
	while os.clock() < deadline and not shouldStop() do
		task.wait(math.min(0.25, deadline - os.clock()))
	end
end

-- A save running this long has probably hung, and must not stop this player's progress from being saved
function Session.hasSaveHung(soul: Soul): boolean
	return soul.IsSaving and os.clock() - soul.LastAutoSave >= Config.HUNG_SAVE_TIME
end

-- Waits for the one save that can be running. Gives up if the session moves on or that save seems to have hung.
local function waitForWriter(soul: Soul, state: string)
	local deadline = os.clock() + Config.WRITER_WAIT_TIMEOUT
	while soul.IsSaving and soul.SessionState == state and os.clock() < deadline and not Session.hasSaveHung(soul) do
		task.wait()
	end
end

-- Hooks run on their own thread so one that yields is caught instead of stalling a save or a load.
-- Nothing else can run during one, so this is only true for what a hook itself calls.
local isInsideHook = false

local function runHook(callback: (any) -> any, data: any): (boolean, string?)
	local thread = coroutine.create(callback)
	isInsideHook = true
	local resumed, problem = coroutine.resume(thread, data)
	isInsideHook = false
	if not resumed then
		return false, tostring(problem)
	end
	if coroutine.status(thread) ~= "dead" then
		task.cancel(thread)
		return false, "the hook yielded"
	end
	return true
end

-- Loads and saves wait on the data store, and a hook that waits is cancelled, which would strand whatever it had started.
local function refusedInsideHook(action: string): boolean
	if isInsideHook then
		Logger.warn("%s => Cannot be called from inside a load or save hook", action)
	end
	return isInsideHook
end

-- The transform must hand back the key's user ids and metadata, or Roblox clears them.
local function getKeyAttributes(soul: Soul, keyInfo: any)
	local userIds = if keyInfo then table.clone(keyInfo:GetUserIds()) else {}
	if soul.UserId > 0 and #userIds < MAX_USER_IDS and not table.find(userIds, soul.UserId) then
		table.insert(userIds, soul.UserId)
	end
	return userIds, if keyInfo then keyInfo:GetMetadata() else {}
end

local function updateRecord(soul: Soul, transform: (oldData: any, keyInfo: any) -> ...any)
	return pcall(function()
		return Session.getDatastore(soul.DatastoreId, soul.Scope):UpdateAsync(soul.DatastoreKey, transform)
	end)
end

-- The same problem comes back every autosave, so each is reported once per session.
local function warnOnce(soul: Soul, problem: string, paths: { string })
	local text = problem .. ": " .. table.concat(paths, ", ")
	if not soul._warned[text] then
		soul._warned[text] = true
		Logger.warn("SaveData => %s for %s", text, describe(soul))
	end
end

-- Copies base and prepares it to be written. Live data is never touched. Returns nil if the hook failed.
local function buildPayload(soul: Soul, base: any, useHook: boolean): any?
	local payload = DeepCopyUtil.deepCopy(base)
	local metaData = if typeof(payload.MetaData) == "table" then payload.MetaData else {}

	if useHook and soul._onSave then
		local ok, problem = runHook(soul._onSave, payload)
		if not ok then
			Logger.warn("SaveData => OnSave hook failed for %s: %s", describe(soul), tostring(problem))
			return nil
		end
	end
	payload.MetaData = metaData

	local removed, reshaped, notNumbers = DataValidator.removeUnstorable(payload)
	if #removed > 0 then
		warnOnce(soul, "Dropped values a data store cannot hold", removed)
	end
	if #reshaped > 0 then
		warnOnce(soul, "These tables will not load back the same. Use plain arrays or string keys", reshaped)
	end
	if #notNumbers > 0 then
		warnOnce(soul, "Saving NaN, which is usually a bug in the game", notNumbers)
	end
	return payload
end

--[[
	Makes one write attempt, which goes through only while the stored record still names this session's token.
	A session that has lost its token must never write again, whatever the lock or its expiry say. Those two only
	decide whether a new session may claim the record.

	Roblox may run a transform more than once, so every metadata field is set from the record it was given.
]]
local function writeRecord(soul: Soul, payload: any, isFinal: boolean): (string, any)
	-- Only the newest write may land. One that hung and comes back late holds older data than the one after it.
	soul._newestWrite += 1
	local thisWrite = soul._newestWrite
	local outcome = nil
	local ok, result = updateRecord(soul, function(oldData, keyInfo)
		outcome = nil
		if thisWrite ~= soul._newestWrite then
			outcome = "Superseded"
			return nil
		end

		local stored = if typeof(oldData) == "table" then oldData.MetaData else nil
		local canSave = typeof(stored) == "table" and stored.SessionId == soul.SessionToken
		if not canSave then
			-- A retry can find the release its own earlier attempt wrote, when only the response was lost
			local alreadySaved = isFinal
				and soul._finalSaveId ~= nil
				and typeof(stored) == "table"
				and stored.Locked == false
				and stored.SessionId == ""
				and stored.SaveId == soul._finalSaveId
			outcome = if alreadySaved then "AlreadySaved" else "Refused"
			return nil
		end

		local metaData = payload.MetaData
		metaData.SaveId = (tonumber(stored.SaveId) or 0) + 1
		metaData.LastUpdate = os.time()
		metaData.Locked = not isFinal
		metaData.SessionId = if isFinal then "" else soul.SessionToken
		if isFinal then
			soul._finalSaveId = metaData.SaveId
		end
		outcome = "Saved"
		return payload, getKeyAttributes(soul, keyInfo)
	end)

	if not ok then
		return "Failed", result
	elseif outcome == "Refused" then
		return "Refused", nil
	elseif outcome == "AlreadySaved" then
		return "Saved", nil
	elseif outcome == "Saved" and result ~= nil then
		return "Saved", result
	elseif outcome == "Superseded" then
		return "Failed", "a newer save started while this one was running"
	end
	-- Neither refused nor confirmed, which is what a failing transform looks like: Roblox prints why, raises nothing and
	-- writes nothing. The next attempt reads the record and finds out what really happened.
	return "Failed", "the data store returned no result"
end

-- Clears a lock only if this session holds it. Returns false if the store could not answer in time.
local function releaseOwnedRecord(soul: Soul, timeout: number): boolean
	local deadline = os.clock() + timeout
	local retryDelay = Config.RETRY_INTERVAL
	repeat
		local ok, result = updateRecord(soul, function(oldData, keyInfo)
			local metaData = if typeof(oldData) == "table" then oldData.MetaData else nil
			if typeof(metaData) ~= "table" or metaData.SessionId ~= soul.SessionToken then
				return nil
			end
			metaData.SaveId = (tonumber(metaData.SaveId) or 0) + 1
			metaData.Locked = false
			metaData.SessionId = ""
			metaData.LastUpdate = os.time()
			return oldData, getKeyAttributes(soul, keyInfo)
		end)
		if ok then
			return true
		end
		if not isRetryable(result) then
			return false
		end

		task.wait(math.min(retryDelay, deadline - os.clock()))
		retryDelay = nextRetryDelay(retryDelay, Config.MAX_RETRY_INTERVAL)
	until os.clock() >= deadline
	return false
end

-- The one place a session ends. Fires the end event exactly once.
function Session.settle(soul: Soul, state: string, reason: string)
	if Session.isSettled(soul) then
		return
	end

	soul.SessionState = state
	soul.EndReason = reason
	soul.SaveState = SAVE_STATES.SessionEnding
	if state == SESSION_STATES.Cancelled then
		soul.LoadState = LOAD_STATES.Idle
	end
	table.clear(soul._Listeners)
	SessionCache.remove(soul)

	local log = if reason == "Saved" or reason == "Cancelled" then Logger.info else Logger.warn
	log("Session for %s settled: %s (%s)", describe(soul), state, reason)
	soul.SessionEndBindableEvent:Fire(state, reason)
	soul.SessionEndBindableEvent:Destroy()
end

---------------------------------------------------------------------------------------------------------------- Loading

local function cancelAcquisition(soul: Soul, uncertain: boolean, reason: string?): (boolean, string?)
	local finalReason = reason or "Cancelled"
	if uncertain and not releaseOwnedRecord(soul, Config.ACQUISITION_RECOVERY_TIMEOUT) then
		finalReason = "AcquisitionUncertain"
	end
	Session.settle(soul, SESSION_STATES.Cancelled, finalReason)
	return false, soul.EndReason
end

local function finishAcquisition(soul: Soul, data: any): (boolean, string?)
	local metaData = DeepCopyUtil.deepCopy(data.MetaData)
	if soul._onLoad then
		local ok, problem = runHook(soul._onLoad, data)
		if not ok then
			Logger.warn("LoadData => OnLoad hook failed for %s: %s", describe(soul), tostring(problem))
			-- The stored record is untouched: the hook only changed this copy.
			return cancelAcquisition(soul, true, "HookFailed")
		end
	end

	-- PlayerRemoving may have fired while the claim was in flight, so nothing else will ever end this session
	if
		soul._cancelRequested
		or soul.SessionState ~= SESSION_STATES.Pulling
		or not Session.playerExists(soul.Player)
	then
		return cancelAcquisition(soul, true)
	end

	data.MetaData = metaData
	soul.Data = data
	soul._defaultData = nil
	soul.SessionState = SESSION_STATES.Active
	soul.LoadState = LOAD_STATES.Loaded
	-- Spreads autosaves over the whole interval, where they stay, even when many players arrive together.
	soul.LastAutoSave = os.clock() - math.random(0, math.floor(Config.AUTO_SAVE_INTERVAL))
	Logger.info("LoadData => Loaded %s (SaveId: %s)", describe(soul), tostring(metaData.SaveId))
	return true
end

-- Roblox's own timestamp where there is one, so that only this server's clock can be wrong.
local function getLockAge(metaData: any, keyInfo: any): number
	local writtenAt = if keyInfo and keyInfo.UpdatedTime
		then keyInfo.UpdatedTime / 1000
		else tonumber(metaData.LastUpdate) or 0
	return os.time() - writtenAt
end

-- How long a load must see a lock not change before taking it. A lock past the expiry only gets a short look, because
-- after an outage every lock looks that old and its owner may only be waiting to land its final save, which must not
-- lose the race for the lock. A lock that looks newer is still taken after watching it for the whole expiry, in case
-- this server's clock is slow.
local function getTakeoverTime(age: number): number
	return if age >= Config.SESSION_EXPIRY then Config.TAKEOVER_DELAY else Config.SESSION_EXPIRY
end

local function acquireSession(soul: Soul): (boolean, string?)
	local uncertain = false
	local retryDelay = Config.RETRY_INTERVAL
	local watchedLock, watchedSince = nil, 0
	local function shouldStop(): boolean
		return soul._cancelRequested
			or soul.SessionState ~= SESSION_STATES.Pulling
			or not Session.playerExists(soul.Player)
	end

	while true do
		if shouldStop() then
			return cancelAcquisition(soul, uncertain)
		end

		local outcome, takeoverTime, seenLock = nil, nil, nil
		local ok, result = updateRecord(soul, function(oldData, keyInfo)
			outcome, takeoverTime, seenLock = nil, nil, nil

			-- The player left while this request was queued, so there is nothing to claim
			if shouldStop() then
				return nil
			end

			local data = oldData
			if data == nil then
				-- new players don't have data yet so we will copy the default data
				data = DeepCopyUtil.deepCopy(soul._defaultData)
			elseif
				typeof(data) ~= "table"
				or (data.MetaData ~= nil and typeof(data.MetaData) ~= "table")
				or #data > 0 -- An array cannot hold MetaData, so this session could never own it
			then
				outcome = "Corrupt"
				return nil
			end

			local metaData = data.MetaData
			if metaData then
				--[[
					Conditions that make it so we can't claim the session:
					Locked by someone else, and written to since we started watching it. Our own token means an earlier
					attempt committed and only its response was lost.
				]]
				if metaData.Locked and metaData.SessionId ~= soul.SessionToken then
					local lockId = tostring(metaData.SessionId) .. ":" .. tostring(metaData.SaveId)
					local silentFor = if lockId == watchedLock then os.clock() - watchedSince else 0
					local needed = getTakeoverTime(getLockAge(metaData, keyInfo))
					if silentFor < needed then
						outcome, takeoverTime, seenLock = "Locked", needed, lockId
						return nil
					end
				end
			else
				-- create meta data onto data if it doesn't have
				metaData = Session.getMetaData()
				data.MetaData = metaData
			end

			metaData.SaveId = (tonumber(metaData.SaveId) or 0) + 1
			metaData.SessionId = soul.SessionToken
			metaData.Locked = true
			metaData.LastUpdate = os.time()
			outcome = "Acquired"
			return data, getKeyAttributes(soul, keyInfo)
		end)

		if ok and outcome == "Acquired" and result ~= nil then
			return finishAcquisition(soul, result)
		elseif ok and outcome == "Corrupt" then
			Logger.warn("LoadData => Save for %s is malformed; not touching it", describe(soul))
			return cancelAcquisition(soul, false, "CorruptData")
		elseif ok and outcome == "Locked" then
			-- Being refused proves no earlier attempt of ours holds the lock
			uncertain = false
			if seenLock ~= watchedLock then
				watchedLock, watchedSince = seenLock, os.clock()
			end
			local secondsLeft = takeoverTime - (os.clock() - watchedSince)
			Logger.warn("LoadData => Data for %s is locked. Takeover in at most: %d(s)", describe(soul), secondsLeft)
			waitUnless(Config.LOAD_ATTEMPT_INTERVAL, shouldStop)
		elseif ok and outcome == nil and shouldStop() then
			continue -- The transform saw the player leave, and the check at the top of the loop handles that
		else
			-- A failed request says nothing about the lock's owner, which may be failing the same way
			watchedLock = nil
			-- No error and no value means the transform itself failed. Roblox prints why, and writes nothing.
			local problem = if ok then "the data store returned no result" else result
			Logger.warn("LoadData => Failed to load data for %s. Error Reason: %s", describe(soul), tostring(problem))
			if not isRetryable(problem) then
				return cancelAcquisition(soul, uncertain, "DataStoreError")
			end
			-- The request may have committed before it failed, so from here this session might hold the lock.
			uncertain = true
			waitUnless(retryDelay, shouldStop)
			retryDelay = nextRetryDelay(retryDelay, Config.MAX_RETRY_INTERVAL)
		end
	end
end

-- Takes the session lock and loads the record. Returns true once active; otherwise false and the reason.
function Session.load(soul: Soul): (boolean, string?)
	if refusedInsideHook("LoadData") then
		return false, "CalledFromHook"
	end

	-- Concurrent callers share one load
	while soul._isLoading do
		task.wait()
	end

	if soul.SessionState == SESSION_STATES.Active then
		return true
	elseif soul.SessionState ~= SESSION_STATES.Pulling then
		return false, soul.EndReason or soul.SessionState
	end

	soul._isLoading = true
	soul.LoadState = LOAD_STATES.Loading
	local ok, loaded, reason = pcall(acquireSession, soul)
	soul._isLoading = false

	if not ok then
		Logger.warn("LoadData => Load for %s errored: %s", describe(soul), tostring(loaded))
		return cancelAcquisition(soul, true, "InternalError")
	end
	return loaded, reason
end

----------------------------------------------------------------------------------------------------------- Normal saves

-- Copies only the fields a save decides. A table replaced wholesale would lose changes made during the save, and
-- anything else the game keeps in MetaData.
local function applyConfirmedMetaData(soul: Soul, confirmed: any)
	local live = soul.Data.MetaData
	if typeof(live) ~= "table" then
		live = {}
		soul.Data.MetaData = live
	end
	live.SaveId = confirmed.SaveId
	live.LastUpdate = confirmed.LastUpdate
	live.Locked = confirmed.Locked
	live.SessionId = confirmed.SessionId
end

local function performRegularSave(soul: Soul): (boolean, string?)
	local payload = buildPayload(soul, soul.Data, true)
	if not payload then
		return false, "HookFailed"
	end

	-- One attempt on purpose: the next autosave carries newer data anyway, and the caller gets an answer right away.
	local outcome, detail = writeRecord(soul, payload, false)
	if outcome == "Saved" then
		applyConfirmedMetaData(soul, detail.MetaData)
		Logger.info("SaveData => Saved %s (SaveId: %s)", describe(soul), tostring(detail.MetaData.SaveId))
		return true
	elseif outcome == "Refused" then
		-- A final save that started meanwhile clears the token itself, so only an active session has really lost it
		if soul.SessionState == SESSION_STATES.Active then
			Session.settle(soul, SESSION_STATES.Ended, "OwnershipLost")
		end
		return false, "OwnershipLost"
	end

	Logger.warn("SaveData => Failed to save data for %s. Error Reason: %s", describe(soul), tostring(detail))
	return false, if isRetryable(detail) then "SaveFailed" else "SaveRejected"
end

-- Returns true only when this data was confirmed written; otherwise false and the reason.
function Session.save(soul: Soul): (boolean, string?)
	if refusedInsideHook("SaveData") then
		return false, "CalledFromHook"
	end

	-- Queue behind a save already running: the caller's changes may not be in that snapshot.
	waitForWriter(soul, SESSION_STATES.Active)
	if not Session.isUsable(soul) then
		return false, soul.EndReason or soul.SessionState
	end
	if soul.IsSaving and not Session.hasSaveHung(soul) then
		return false, SAVE_STATES.Saving
	end

	soul.IsSaving = true
	soul.SaveState = SAVE_STATES.Saving
	soul.LastAutoSave = os.clock()

	local ok, saved, reason = pcall(performRegularSave, soul)
	soul.IsSaving = false
	if soul.SessionState == SESSION_STATES.Active then
		soul.SaveState = SAVE_STATES.Idle
	end
	if not ok then
		Logger.warn("SaveData => Save for %s errored: %s", describe(soul), tostring(saved))
		return false, "InternalError"
	end
	return saved, reason
end

------------------------------------------------------------------------------------------------------------ Final saves

local function rejectFinalSave(soul: Soul, problem: string): (boolean, string)
	Logger.warn("SaveData => Final save for %s cannot be written: %s", describe(soul), problem)
	-- Nothing newer can reach the store, so free the player's save now rather than making them wait out the lock.
	releaseOwnedRecord(soul, Config.ACQUISITION_RECOVERY_TIMEOUT)
	Session.settle(soul, SESSION_STATES.Ended, "SaveRejected")
	return false, "SaveRejected"
end

local function finalizeSession(soul: Soul, payload: any?): (boolean, string?)
	-- If that save has hung, stop waiting: it cannot land after this write, which clears the token it checks for.
	waitForWriter(soul, SESSION_STATES.Ending)
	if soul.SessionState ~= SESSION_STATES.Ending then
		return false, soul.EndReason
	end
	soul.IsSaving = true

	if not payload then
		return rejectFinalSave(soul, "the session's data could not be copied")
	end

	local retryDelay = Config.RETRY_INTERVAL
	while soul.SessionState == SESSION_STATES.Ending do
		local outcome, detail = writeRecord(soul, payload, true)
		if outcome == "Saved" then
			Session.settle(soul, SESSION_STATES.Ended, "Saved")
			return true
		elseif outcome == "Refused" then
			Session.settle(soul, SESSION_STATES.Ended, "OwnershipLost")
			return false, "OwnershipLost"
		end

		Logger.warn("SaveData => Failed final save for %s. Error Reason: %s", describe(soul), tostring(detail))
		if not isRetryable(detail) then
			return rejectFinalSave(soul, tostring(detail))
		end

		waitUnless(retryDelay, function()
			return soul.SessionState ~= SESSION_STATES.Ending
		end)
		retryDelay = nextRetryDelay(retryDelay, Config.MAX_FINAL_SAVE_RETRY_INTERVAL)
	end
	return false, soul.EndReason
end

-- Ends a session: cancels a load in progress, or writes the final save and releases the lock.
function Session.finish(soul: Soul): (boolean, string?)
	if soul.SessionState == SESSION_STATES.Pulling then
		soul._cancelRequested = true
		if not soul._isLoading then
			Session.settle(soul, SESSION_STATES.Cancelled, "Cancelled")
		end
		return false, "Cancelled"
	elseif soul.SessionState ~= SESSION_STATES.Active or soul._isSealing then
		return false, soul.EndReason or SESSION_STATES.Ending
	elseif refusedInsideHook("SaveData") then
		return false, "CalledFromHook"
	end

	-- The final copy and the hook happen here, before anything can yield, so nothing that runs later can change them.
	-- The state only changes afterwards, so a hook folding in-memory progress into the copy can still read the session.
	soul._isSealing = true
	local built, payload = pcall(buildPayload, soul, soul.Data, true)
	if not (built and payload) then
		-- A failed hook must not cost the player the rest of their progress
		built, payload = pcall(buildPayload, soul, soul.Data, false)
	end
	if not built then
		Logger.warn("SaveData => Could not copy %s: %s", describe(soul), tostring(payload))
		payload = nil
	end
	soul.SessionState = SESSION_STATES.Ending
	soul.SaveState = SAVE_STATES.SessionEnding

	local ok, saved, why = pcall(finalizeSession, soul, payload)
	soul.IsSaving = false
	if not ok then
		Logger.warn("SaveData => Final save for %s errored: %s", describe(soul), tostring(saved))
		Session.settle(soul, SESSION_STATES.Ended, "InternalError")
		return false, "InternalError"
	end
	return saved, why
end

return Session
