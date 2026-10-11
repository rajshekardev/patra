package config

import "patra:config"
import "patra:env"

// env.dev loads for patra dev if available else loads .env 
// env.prod loads for build, deploy else loads .env 

app :: config.App{
	name = "demo",
	db = config.postgres(url = env.DATABASE_URL),
	tailwind = .Project, // uses tailwind form package.json leave it empty to use bundled tailwindcss

	dev = {
		port = 3000,
	},
	build = {
		runtime = .Native,// .Bun, .Node, .Deno, .Worker, .Native
		mode = .SERVER // serverless or server
	},
	deploy = {
		platform = .Render, // vercel, cloudflare, render, fly.io
		environment = .Native,// .Bun, .Node, .Deno, .Docker, .Worker
	}
}
