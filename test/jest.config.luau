--!nonstrict
-- Shared by Studio and Lune. Instance-valued paths must stay in a Luau config.
return {
	rootDir = script.Parent.Specs,
	roots = { script.Parent.Specs },
	testMatch = { "**/*.spec" },
	setupFilesAfterEnv = { script.Parent.JestSetup },
	injectGlobals = false,
	clearMocks = true,
	restoreMocks = true,
	-- Keep explicitly configured mocks and module identities within a spec.
	resetMocks = false,
	resetModules = false,
	mockDataModel = false,
	testTimeout = 10000,
	passWithNoTests = false,
}
