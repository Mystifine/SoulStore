local DeepCopyUtil = {}

--[[
	Deep copies data. A table is cloned rather than rebuilt key by key, because that keeps its length, and Roblox stops an
	array at its length: rebuilt, an array with a gap in it can come out shorter than it went in.

	@param data : any? - The data to copy

	@return any? - The copied data
]]
function DeepCopyUtil.deepCopy(data: any?)
	-- Deep copy the data
	if typeof(data) == "buffer" then
		return buffer.fromstring(buffer.tostring(data))
	elseif typeof(data) ~= "table" then
		return data
	end

	local copiedData
	if getmetatable(data) then
		-- A metatable is not data, so it stays behind, which table.clone would not do
		copiedData = {}
		for i, v in pairs(data) do
			copiedData[i] = v
		end
	else
		copiedData = table.clone(data)
	end

	for i, v in pairs(copiedData) do
		local kind = typeof(v)
		if kind == "table" or kind == "buffer" then
			copiedData[i] = DeepCopyUtil.deepCopy(v)
		end
	end

	return copiedData
end

return DeepCopyUtil
