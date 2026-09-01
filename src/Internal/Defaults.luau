--!strict
-- Timeout defaults. The client waits only on the handshake; a server load can sit
-- behind a session steal, which is the 30 against the 60.

return table.freeze({
	ClientWaitForData = 30,
	ServerWaitForData = 60,
	Request = 10,
	OwnsAsync = 10,
	ProductInfo = 10,
	AwaitBudget = 120,
})
