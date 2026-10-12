package config

Architecture :: enum {Full_Stack, Split}
Mode :: enum {Server, Serverless, Static}
Runtime :: enum {Native, Bun, Node, Worker, None}
Platform :: enum {Render, Fly, Vercel, Cloudflare}
Deployment_Method :: enum {CLI, Manual}

Dev_Config :: struct {port: int}
Backend_Config :: struct {mode: Mode, runtime: Runtime, platform: Platform, deployment: Deployment_Method}
Frontend_Config :: struct {mode: Mode, ssr: bool, runtime: Runtime, platform: Platform, deployment: Deployment_Method}

App :: struct {
	name: string,
	architecture: Architecture,
	dev: Dev_Config,
	backend: Backend_Config,
	frontend: Frontend_Config,
	vite: bool,
	tailwind: string,
	effect: bool,
}

app :: App{
	name = "demo",
	architecture = .Full_Stack,
	dev = {
		port = 3000,
	},
	backend = {
		mode = .Serverless,
		runtime = .Bun,
		platform = .Vercel,
		deployment = .CLI,
	},
	frontend = {
		mode = .Serverless,
		ssr = true,
		runtime = .Bun,
		platform = .Vercel,
		deployment = .CLI,
	},
	vite = false,
	tailwind = "CLI",
	effect = false,
}
