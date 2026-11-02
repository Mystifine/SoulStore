-- What a data store can and cannot hold. Each check returns a description of the problem, or nil if there is none.
-- Tested against real data stores: tests/studio/DataStoreProbe.server.luau shows what Roblox does with each of these.
--
-- Roblox goes by a table's length, #t. A table with a length is stored as an array: keys 1 to that length, gaps included,
-- and every other key is lost. A table with no length is stored as a dictionary, with its number keys turned into strings.

local DataValidator = {}

local function getScalarProblem(value: any): string?
	local kind = typeof(value)
	if kind == "string" then
		return if utf8.len(value) then nil else "a string that is not valid UTF-8"
	elseif kind == "number" or kind == "boolean" or kind == "nil" or kind == "table" or kind == "buffer" then
		return nil
	end
	return "a value of type " .. kind
end

function DataValidator.getKeyProblem(key: any): string?
	local kind = typeof(key)
	if kind ~= "string" and kind ~= "number" then
		return "a table key of type " .. kind
	elseif key == math.huge or key == -math.huge or key ~= key then
		return "a table key that is not a real number"
	end
	return getScalarProblem(key)
end

local function isArrayIndex(key: number): boolean
	return key >= 1 and key % 1 == 0
end

local function getProblemBelow(value: any, ancestors: { [any]: boolean }): string?
	-- A data store can hold NaN, but it is always a bug, and refusing it here keeps the value it would have replaced
	local problem = if value ~= value then "a NaN" else getScalarProblem(value)
	if problem or typeof(value) ~= "table" then
		return problem
	end

	if ancestors[value] then
		return "a table that contains itself"
	end

	ancestors[value] = true
	local hasNumberKey, hasStringKey, isPlainIndexes = false, false, true
	for key, child in pairs(value) do
		local childProblem = DataValidator.getKeyProblem(key) or getProblemBelow(child, ancestors)
		if childProblem then
			return childProblem .. " under '" .. tostring(key) .. "'"
		end
		if typeof(key) == "number" then
			hasNumberKey = true
			isPlainIndexes = isPlainIndexes and isArrayIndex(key)
		else
			hasStringKey = true
		end
	end
	ancestors[value] = nil

	if hasNumberKey and (hasStringKey or not isPlainIndexes or #value == 0) then
		return "a table with number keys that are not an array"
	end
	return nil
end

function DataValidator.getValueProblem(value: any): string?
	return getProblemBelow(value, {})
end

-- Whether writing this key would leave its table something a data store changes or loses
function DataValidator.getWriteProblem(parent: any, key: any, value: any): string?
	if value == nil then
		return nil
	end

	local hasLength = #parent > 0
	if typeof(key) == "string" and not hasLength then
		return nil
	elseif typeof(key) == "number" and (not isArrayIndex(key) or (not hasLength and key ~= 1)) then
		return "a number key that does not continue an array"
	end

	-- A table can already have both, written directly. One more string key changes nothing, and the save copes with it.
	local hasStringKey = false
	for parentKey in pairs(parent) do
		if typeof(parentKey) == "string" then
			hasStringKey = true
			break
		end
	end
	if typeof(key) == "number" then
		return if hasStringKey then "a number key on a table with string keys" else nil
	end
	return if hasStringKey then nil else "a string key on an array"
end

local function moveNumberKeysToStrings(node: any)
	local moved = {}
	for key in pairs(node) do
		if typeof(key) == "number" then
			table.insert(moved, key)
		end
	end
	for _, key in ipairs(moved) do
		local value = node[key]
		node[key] = nil
		node[tostring(key)] = value
	end
end

--[[
	Makes a copy of the data safe to write, so that nothing in it can cost the player anything else, and nothing in it is
	quietly lost.

	Removes what a data store can never hold, because one bad value would otherwise fail the whole save, and a boolean key
	would silently cancel it. An array with a gap that would stop it short gets the length it needs. Number keys that would
	be lost, because their table also has string keys or is too sparse to be an array, are stored as strings instead. That
	way a stray number key at the top of a save cannot wipe out every named field in it. Whatever will load back different
	is reported. NaN is only reported, since it comes back as it went in.

	@param container : {} - The table to clean, which is changed in place
	@return The path of everything removed, of each table that would come back different, and of each NaN
]]
function DataValidator.removeUnstorable(container: any): ({ string }, { string }, { string })
	local removed, reshaped, notNumbers, keys = {}, {}, {}, {}

	local function visit(node: any, depth: number): any
		local numberKeys, largestKey, hasStringKey, isPlainIndexes, isFractional = 0, 0, false, true, false
		for key, value in pairs(node) do
			keys[depth] = tostring(key)
			if DataValidator.getKeyProblem(key) or getScalarProblem(value) then
				node[key] = nil
				table.insert(removed, table.concat(keys, ".", 1, depth))
				continue
			end

			if typeof(key) == "number" then
				numberKeys += 1
				largestKey = math.max(largestKey, key)
				isPlainIndexes = isPlainIndexes and isArrayIndex(key)
				isFractional = isFractional or key % 1 ~= 0
			else
				hasStringKey = true
			end
			if typeof(value) == "table" then
				node[key] = visit(value, depth + 1)
			elseif value ~= value then
				table.insert(notNumbers, table.concat(keys, ".", 1, depth))
			end
		end

		if numberKeys == 0 then
			return node
		end

		local isArray = isPlainIndexes and not hasStringKey
		if isArray and largestKey <= #node then
			return node
		elseif isArray and largestKey <= numberKeys * 4 then
			-- Created at its full size, its length runs to the end, and its gaps come back as gaps
			local whole = table.create(largestKey)
			for key, value in pairs(node) do
				whole[key] = value
			end
			return whole
		end

		-- Without a length Roblox keeps every key by itself, unless two fractions would round to the same one
		if #node > 0 or isFractional then
			moveNumberKeysToStrings(node)
		end
		table.insert(reshaped, if depth == 1 then "the whole save" else table.concat(keys, ".", 1, depth - 1))
		return node
	end

	visit(container, 1)
	return removed, reshaped, notNumbers
end

return DataValidator
