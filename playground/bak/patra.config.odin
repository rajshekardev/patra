package config

import "patra"

app:: patra.Config{
	name = "Demo"	,

	dev = {
		port = 3000,
	},
	build = {
		runtime = .Bun,
		mode = .Server
	},
	deploy = {
		platform = .Vercel,
		environment = .Bun
	}
}
