-- The types SoulStore exports. init.luau re-exports them for callers.

export type SoulMetaData = {
	Locked: boolean,
	SaveId: number,
	LastUpdate: number,
	SessionId: string,
}

export type Soul = {
	Player: Player,
	UserId: number,
	DatastoreId: string,
	Scope: string,
	DatastoreKey: string,
	SessionToken: string,

	Data: { MetaData: SoulMetaData },
	LastAutoSave: number,
	IsSaving: boolean,

	SessionState: string,
	EndReason: string?,
	LoadState: string,
	SaveState: string,
	SessionEndBindableEvent: BindableEvent,

	-- Private to SoulStore
	_Listeners: { [string]: { any } },
	_onSave: ((dataToBeSaved: {}) -> ())?,
	_onLoad: ((dataToBeLoaded: {}) -> ())?,
	_defaultData: {}?,
	_newestWrite: number,
	_warned: { [string]: boolean },
	_isLoading: boolean,
	_isSealing: boolean,
	_cancelRequested: boolean,
	_finalSaveId: number?,

	OnDataChanged: (
		self: Soul,
		path: { any }?,
		callback: (oldData: any?, newData: any?) -> ()
	) -> { Disconnect: () -> () },
	SetData: (self: Soul, path: { any }, value: any) -> any?,
	GetData: (self: Soul, path: { any }?) -> any?,
	Reconcile: (self: Soul, data: {}?) -> (),
	SaveData: (self: Soul, sessionEnding: boolean?) -> (boolean, string?),
	LoadData: (self: Soul) -> (boolean, string?),
	SetOnSave: (self: Soul, callback: (dataToBeSaved: {}) -> ()) -> (),
	SetOnLoad: (self: Soul, callback: (dataToBeLoaded: {}) -> ()) -> (),
}

export type SoulStore = {
	ClassName: string,

	new: (datastoreId: string, scope: string?, player: Player, defaultData: {}) -> Soul?,
	getSoul: (datastoreId: string, scope: string?, player: Player) -> Soul?,
	getPendingSoul: (datastoreId: string, scope: string?, player: Player) -> Soul?,
	getEndingSoul: (datastoreId: string, scope: string?, player: Player) -> Soul?,
	hasActiveSession: (datastoreId: string, scope: string?, player: Player) -> boolean,
	getDatastore: (datastoreId: string, scope: string?) -> DataStore,
	getMetaData: (sessionToken: string?) -> SoulMetaData,
	deepCopy: (data: any?) -> any,
	output: (outputFunction: (any) -> any, ...any) -> (),
	playerExists: (player: Player?) -> boolean,
	resetData: (datastoreId: string, scope: string?, datastoreKey: string) -> boolean,
	resetAllData: (datastoreId: string, scope: string?, confirmation: string?) -> boolean,
}

return {}
