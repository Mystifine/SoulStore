local Config = require(script.Parent.Config)

local Logger = {}

--[[
	Outputs a message to the console with optional debug and traceback support

	@param outputFunction : (any) -> any - The function to output the message (e.g., print, warn)
	@param ... : any - The arguments to pass to the output function
]]
function Logger.output(outputFunction: (any) -> any, ...)
	-- Warnings are how a failing save gets noticed, so DEBUG_MODE never hides them
	if outputFunction ~= warn and not Config.DEBUG_MODE then
		return
	end

	local message = table.concat({ ... }, " ")
	if Config.TRACE_BACK_MESSAGE then
		message ..= "\nTraceback:" .. debug.traceback()
	end
	outputFunction(message)
end

-- Always shown. Takes the same arguments as string.format.
function Logger.warn(format: string, ...)
	Logger.output(warn, "[SoulStore] " .. string.format(format, ...))
end

-- Only shown with DEBUG_MODE on. Takes the same arguments as string.format.
function Logger.info(format: string, ...)
	Logger.output(print, "[SoulStore] " .. string.format(format, ...))
end

return Logger
