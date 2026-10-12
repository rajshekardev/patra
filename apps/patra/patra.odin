package patra

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Value :: struct {
	name: string,
	value: string,
}

Route :: struct {
	source: string,
	url: string,
	markup: string,
	server: string,
	client: string,
	script: string,
	script_ts: bool,
	style: string,
	title: string,
	data: []Value,
}

Build_Config :: struct {
	name: string,
	runtime: string,
	mode: string,
	port: string,
	tailwind: string,
	platform: string,
	vite: bool,
}

index_of :: proc(text, needle: string) -> int {
	return strings.index(text, needle)
}

read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return "", false
	return string(data), true
}

write_text :: proc(path, contents: string) -> bool {
	dir, _ := filepath.split(path)
	if dir != "" && !os.is_directory(dir) {
		if err := os.make_directory_all(dir); err != nil {
			fmt.eprintln("Could not create output directory", dir, ":", err)
			return false
		}
	}
	if err := os.write_entire_file(path, contents); err != nil {
		fmt.eprintln("Could not write output file", path, ":", err)
		return false
	}
	return true
}

replace_all :: proc(text, old, new: string) -> string {
	if old == "" do return text
	b := strings.builder_make()
	cursor := 0
	for {
		i := strings.index(text[cursor:], old)
		if i < 0 do break
		i += cursor
		strings.write_string(&b, text[cursor:i])
		strings.write_string(&b, new)
		cursor = i + len(old)
	}
	strings.write_string(&b, text[cursor:])
	return strings.to_string(b)
}

trim :: proc(s: string) -> string {
	return strings.trim_space(s)
}

concat :: proc(a, b: string) -> string {
	result, _ := strings.concatenate({a, b})
	return result
}

json_string :: proc(value: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "\"")
	for c in value {
		if c == '"' do strings.write_string(&b, "\\\"")
		else if c == '\\' do strings.write_string(&b, "\\\\")
		else if c == '\n' do strings.write_string(&b, "\\n")
		else if c == '\r' do strings.write_string(&b, "\\r")
		else if c == '\t' do strings.write_string(&b, "\\t")
		else { strings.write_rune(&b, c) }
	}
	strings.write_string(&b, "\"")
	return strings.to_string(b)
}

path_join :: proc(a, b: string) -> string {
	result, _ := filepath.join({a, b})
	return result
}

value_for :: proc(values: []Value, name: string) -> string {
	for item in values {
		if item.name == name do return item.value
	}
	return ""
}

set_value :: proc(values: ^[dynamic]Value, name, value: string) {
	for item, i in values^ {
		if item.name == name {
			values[i].value = value
			return
		}
	}
	append(values, Value{name, value})
}

add_route_param_placeholders :: proc(route_url: string, values: ^[dynamic]Value) {
	remaining := route_url
	for {
		slash := strings.index(remaining, "/")
		segment := remaining
		if slash >= 0 do segment = remaining[:slash]
		if len(segment) > 2 && segment[0] == '[' && segment[len(segment)-1] == ']' {
			name := segment[1:len(segment)-1]
			token, _ := strings.concatenate({"__PATRA_PARAM_", name, "__"})
			set_value(values, name, token)
		}
		if slash < 0 do break
		remaining = remaining[slash+1:]
	}
}

literal_value :: proc(value: string) -> string {
	v := trim(value)
	if len(v) >= 2 && ((v[0] == '"' && v[len(v)-1] == '"') || (v[0] == '\'' && v[len(v)-1] == '\'')) {
		return v[1:len(v)-1]
	}
	if v == "true" || v == "false" do return v
	for c in v {
		if !((c >= '0' && c <= '9') || c == '.' || c == '-') do return ""
	}
	return v
}

parse_odin_values :: proc(source: string, values: ^[dynamic]Value) {
	for raw_line in strings.split_lines(source) {
		line := trim(raw_line)
		if len(line) == 0 || strings.has_prefix(line, "import ") || strings.has_prefix(line, "//") do continue
		colon := strings.index(line, ":")
		assign := strings.index(line, "=")
		if colon < 1 || assign <= colon do continue
		name := trim(line[:colon])
		if strings.contains(name, " ") || strings.contains(name, "(") do continue
		value := literal_value(line[assign+1:])
		if value != "" do set_value(values, name, value)
	}
}

parse_script_values :: proc(source: string, values: ^[dynamic]Value) {
	for raw_line in strings.split_lines(source) {
		line := trim(raw_line)
		if line == "" || strings.has_prefix(line, "//") do continue
		comment := strings.index(line, "//")
		if comment >= 0 do line = trim(line[:comment])
		keywords := [3]string{"const ", "let ", "var "}
		for keyword in keywords {
			if strings.has_prefix(line, keyword) {
				line = trim(line[len(keyword):])
				break
			}
		}
		assign := strings.index(line, "=")
		if assign <= 0 do continue
		name := trim(line[:assign])
		valid_name := true
		for c, i in name {
			if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' || (i > 0 && c >= '0' && c <= '9')) { valid_name = false; break }
		}
		if !valid_name do continue
		raw_value := trim(line[assign+1:])
		if strings.has_suffix(raw_value, ";") do raw_value = trim(raw_value[:len(raw_value)-1])
		value := literal_value(raw_value)
		if value != "" do set_value(values, name, value)
	}
}

extract_regions :: proc(source: string) -> (markup, server, client, script, style: string, ok: bool) {
	markup_builder := strings.builder_make()
	server_builder := strings.builder_make()
	client_builder := strings.builder_make()
	script_builder := strings.builder_make()
	style_builder := strings.builder_make()
	cursor := 0
	for cursor < len(source) {
		search := source[cursor:]
		odin_at := strings.index(search, "<odin ")
		script_at := strings.index(search, "<script")
		style_at := strings.index(search, "<style")
		at := len(search)
		kind := ""
		if odin_at >= 0 && odin_at < at { at = odin_at; kind = "odin" }
		if script_at >= 0 && script_at < at { at = script_at; kind = "script" }
		if style_at >= 0 && style_at < at { at = style_at; kind = "style" }
		if kind == "" {
			strings.write_string(&markup_builder, search)
			break
		}
		at += cursor
		strings.write_string(&markup_builder, source[cursor:at])
		open_end := strings.index(source[at:], ">")
		if open_end < 0 do return "", "", "", "", "", false
		body_start := at + open_end + 1
		close := ""
		if kind == "odin" do close = "</odin>"
		if kind == "script" do close = "</script>"
		if kind == "style" do close = "</style>"
		body_end := strings.index(source[body_start:], close)
		if body_end < 0 do return "", "", "", "", "", false
		body_end += body_start
		body := source[body_start:body_end]
		if kind == "odin" {
			tag := source[at:body_start]
			if strings.contains(tag, "server") do strings.write_string(&server_builder, body)
			if strings.contains(tag, "client") do strings.write_string(&client_builder, body)
		} else if kind == "script" {
			strings.write_string(&script_builder, body)
		} else {
			strings.write_string(&style_builder, body)
		}
		cursor = body_end + len(close)
	}
	return strings.to_string(markup_builder), strings.to_string(server_builder), strings.to_string(client_builder), strings.to_string(script_builder), strings.to_string(style_builder), true
}

parse_document :: proc(path: string, source: string) -> (route: Route, values: []Value, ok: bool) {
	expanded_source := expand_component_imports(path, source)
	body := expanded_source
	parsed_values: [dynamic]Value
	if strings.has_prefix(expanded_source, "---") {
		front_end := strings.index(expanded_source[3:], "\n---")
		if front_end < 0 do return {}, nil, false
		front_end += 3
		front := expanded_source[3:front_end]
		for line in strings.split_lines(front) {
			colon := strings.index(line, ":")
			if colon <= 0 do continue
			key := trim(line[:colon])
			value := literal_value(line[colon+1:])
			if value != "" do append(&parsed_values, Value{key, value})
		}
		body = expanded_source[front_end+4:]
		if len(body) > 0 && body[0] == '\n' do body = body[1:]
	}
	markup, server, client, script, style, extracted := extract_regions(body)
	if !extracted do return {}, nil, false
	parse_odin_values(server, &parsed_values)
	parse_odin_values(client, &parsed_values)
	_, filename := filepath.split(path)
	base := filepath.stem(filename)
	url := "/"
	if base != "page" && base != "index" do url = concat("/", base)
	script_ts := strings.contains(expanded_source, "lang=\"ts\"") || strings.contains(expanded_source, "lang='ts'") || strings.contains(expanded_source, "lang=ts")
	route = Route{source=path, url=url, markup=markup, server=server, client=client, script=script, script_ts=script_ts, style=style, title=value_for(parsed_values[:], "title"), data=parsed_values[:]}
	return route, parsed_values[:], true
}

escape_html :: proc(value: string) -> string {
	v := replace_all(value, "&", "&amp;")
	v = replace_all(v, "<", "&lt;")
	v = replace_all(v, ">", "&gt;")
	v = replace_all(v, "\"", "&quot;")
	return replace_all(v, "'", "&#39;")
}

expand_component_imports :: proc(source_path, source: string) -> string {
	directory, _ := filepath.split(source_path)
	expanded := source
	for raw_line in strings.split_lines(source) {
		line := trim(raw_line)
		if !strings.has_prefix(line, "import ") do continue
		rest := trim(line[len("import "):])
		from := strings.index(rest, " from ")
		if from <= 0 do continue
		name := trim(rest[:from])
		import_path := trim(rest[from+len(" from "):])
		if strings.has_suffix(import_path, ";") do import_path = trim(import_path[:len(import_path)-1])
		if len(import_path) < 2 do continue
		if (import_path[0] == '"' && import_path[len(import_path)-1] == '"') || (import_path[0] == '\'' && import_path[len(import_path)-1] == '\'') {
			import_path = import_path[1:len(import_path)-1]
		}
		component_path, _ := filepath.join({directory, import_path}, context.allocator)
		component, exists := read_text(component_path)
		if !exists do continue
		expanded = replace_all(expanded, raw_line, "")
		self_closing := concat(concat("<", name), " />")
		self_closing_compact := concat(concat("<", name), "/>" )
		expanded = replace_all(expanded, self_closing, component)
		expanded = replace_all(expanded, self_closing_compact, component)
	}
	return expanded
}

render_markup :: proc(markup: string, values: []Value) -> string {
	b := strings.builder_make()
	cursor := 0
	for cursor < len(markup) {
		open := strings.index(markup[cursor:], "{")
		if open < 0 {
			strings.write_string(&b, markup[cursor:])
			break
		}
		open += cursor
		strings.write_string(&b, markup[cursor:open])
		close := strings.index(markup[open+1:], "}")
		if close < 0 {
			strings.write_string(&b, markup[open:])
			break
		}
		close += open + 1
		name := trim(markup[open+1:close])
		built := string(b.buf[:])
		if strings.has_suffix(built, "onclick=") || strings.has_suffix(built, "onsubmit=") {
			event_name := "onclick"
			if strings.has_suffix(built, "onsubmit=") do event_name = "onsubmit"
			strings.write_string(&b, fmt.tprintf("data-patra-%s=\"%s\"", event_name, escape_html(name)))
		} else if strings.has_prefix(name, "#") || strings.has_prefix(name, ":") || strings.has_prefix(name, "/") {
			strings.write_string(&b, markup[open:close+1])
		} else {
			strings.write_string(&b, escape_html(value_for(values, name)))
		}
		cursor = close + 1
	}
	return strings.to_string(b)
}

apply_layouts :: proc(routes_dir: string, route_path: string, route: ^Route) -> bool {
	directory, _ := filepath.split(route_path)
	for {
		if !strings.has_prefix(directory, routes_dir) do break
		layout_path := concat(directory, "/layout.patra")
		layout_source, exists := read_text(layout_path)
		if exists {
			layout_source = expand_component_imports(layout_path, layout_source)
			layout_markup, server, client, script, style, ok := extract_regions(layout_source)
			if !ok do return false
			route.markup = replace_all(layout_markup, "<slot />", route.markup)
			route.markup = replace_all(route.markup, "<slot/>", route.markup)
			route.markup = replace_all(route.markup, "{children}", route.markup)
			route.server = concat(server, route.server)
			route.client = concat(client, route.client)
			route.script = concat(script, route.script)
			route.style = concat(style, route.style)
		}
		if directory == routes_dir do break
		parent, _ := filepath.split(directory)
		if parent == directory || parent == "" do break
		directory = parent
	}
	return true
}

read_routes :: proc(root: string, dir: string, routes: ^[dynamic]Route) -> bool {
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil do return false
	for entry in entries {
		path := path_join(dir, entry.name)
		if entry.type == .Directory {
			if !read_routes(root, path, routes) do return false
		} else if filepath.ext(path) == ".patra" && filepath.base(path) != "layout.patra" {
			source, read_ok := read_text(path)
			if !read_ok do return false
			route, values, parsed := parse_document(path, source)
			if !parsed do return false
			prefix := concat(path_join(root, "src/routes"), "/")
			rel := path
			if strings.has_prefix(path, prefix) do rel = path[len(prefix):]
			if strings.has_suffix(rel, "/page.patra") do rel = rel[:len(rel)-len("/page.patra")]
			else if strings.has_suffix(rel, ".patra") do rel = rel[:len(rel)-len(".patra")]
			if rel == "" || rel == "page" || rel == "index" {
				route.url = "/"
			} else {
				route.url = concat("/", rel)
			}
			if !apply_layouts(path_join(root, "src/routes"), path, &route) do return false
			append(routes, route)
			_ = values
		}
	}
	return true
}

compile_wasm :: proc(root, out: string, route: Route, route_index: int, block_kind: string, source: string) -> bool {
	if len(trim(source)) == 0 do return true
	package_dir := path_join(path_join(out, ".patra"), fmt.tprintf("%d", route_index))
	if !os.is_directory(package_dir) && os.make_directory_all(package_dir) != nil do return false
	filename := "server.odin" if block_kind == "server" else "client.odin"
	wasm_name := fmt.tprintf("%s-%d.wasm", block_kind, route_index)
	odin_source := concat(concat("package main\n\n", source), `

@(export)
_patra_init :: proc "c" () {}

// JSON-memory ABI v1. Dispatch remains disabled until Patra RPC generation lands.
// JS may grow exported memory, write UTF-8 JSON into the new pages, then call
// _patra_json_dispatch(ptr, len). A negative status means dispatch is unavailable.
@(export)
_patra_json_abi_version :: proc "c" () -> i32 { return 1 }

@(export)
_patra_json_dispatch :: proc "c" (input_ptr, input_len: i32) -> i32 {
	_ = input_ptr
	_ = input_len
	return -1
}

@(export)
_patra_json_result_ptr :: proc "c" () -> i32 { return 0 }

@(export)
_patra_json_result_len :: proc "c" () -> i32 { return 0 }
`)
	source_path := path_join(package_dir, filename)
	wasm_path := path_join(path_join(out, "assets"), wasm_name)
	if !write_text(source_path, odin_source) do return false
	command := []string{"odin", "build", source_path, "-file", "-target:freestanding_wasm32", "-o:size", concat("-out:", wasm_path)}
	state, stdout, stderr, process_err := os.process_exec({command=command, working_dir=root}, context.allocator)
	if process_err != nil || state.exit_code != 0 {
		fmt.eprintln("Odin WASM build failed for", route.source, block_kind)
		fmt.println(string(stderr))
		fmt.println(string(stdout))
		return false
	}
	return true
}

read_config :: proc(path: string) -> (config: Build_Config, ok: bool) {
	text, exists := read_text(path)
	if !exists do return {}, false
	config = Build_Config{name="Patra", runtime="Node", mode="Server", port="3000", tailwind="None"}
	for line in strings.split_lines(text) {
		if strings.contains(line, "name") {
			q1 := strings.index(line, "\"")
			if q1 >= 0 {
				q2 := strings.index(line[q1+1:], "\"")
				if q2 >= 0 do config.name = line[q1+1:q1+1+q2]
			}
		}
		if strings.contains(line, "runtime") do config.runtime = enum_value(line, config.runtime)
		if strings.contains(line, "mode") do config.mode = enum_value(line, config.mode)
		if strings.has_prefix(trim(line), "platform =") do config.platform = enum_value(line, config.platform)
		if strings.has_prefix(trim(line), "vite =") do config.vite = strings.contains(line, "true")
		if strings.has_prefix(trim(line), "tailwind =") {
			q1 := strings.index(line, "\"")
			if q1 >= 0 { q2 := strings.index(line[q1+1:], "\""); if q2 >= 0 do config.tailwind = line[q1+1:q1+1+q2] }
		}
		if strings.contains(line, "port") {
			colon := strings.index(line, "=")
			if colon >= 0 {
				digits := strings.trim_space(line[colon+1:])
				end := strings.index(digits, ",")
				if end >= 0 do digits = digits[:end]
				config.port = trim(digits)
			}
		}
	}
	return config, true
}

enum_value :: proc(line, fallback: string) -> string {
	dot := strings.index(line, ".")
	if dot < 0 do return fallback
	end := dot + 1
	for end < len(line) && ((line[end] >= 'A' && line[end] <= 'Z') || (line[end] >= 'a' && line[end] <= 'z')) do end += 1
	if end == dot+1 do return fallback
	return line[dot+1:end]
}

write_runtime :: proc(out: string, config: Build_Config) -> bool {
	runtime := `(()=>{const tag=document.currentScript;globalThis.PatraScripts??={};const load=async path=>{if(!path)return null;const response=await fetch(path);if(!response.ok)throw Error("Could not load Patra Wasm: "+path);const result=await WebAssembly.instantiateStreaming(response,{});const instance=result.instance;if(instance.exports._patra_json_abi_version?.()!==1)throw Error("Unsupported Patra Wasm ABI");instance.exports._patra_init?.();return instance};const ready=load(tag?.dataset.patraClientWasm||"");globalThis.Patra={wasm:null,ready,patch:(target,html)=>{const n=typeof target==="string"?document.querySelector(target):target;if(n)n.innerHTML=html},call:(name,...args)=>fetch("/__patra/rpc/"+name,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(args)}).then(r=>{if(!r.ok)throw Error("Patra RPC "+r.status);return r.json()})};document.addEventListener("submit",e=>{const f=e.target.closest("[data-patra-onsubmit]");if(f)globalThis.PatraScripts?.[f.dataset.patraOnsubmit]?.(e)});document.addEventListener("click",e=>{const n=e.target.closest("[data-patra-onclick]");if(n)globalThis.PatraScripts?.[n.dataset.patraOnclick]?.(e)});ready.then(instance=>{globalThis.Patra.wasm=instance;if(tag?.dataset.patraScript)import(tag.dataset.patraScript)}).catch(error=>console.error("Patra client startup failed",error))})();`
	if !write_text(concat(out, "/assets/patra.js"), runtime) do return false
	if config.runtime == "Worker" || config.runtime == "None" do return true
	server := `import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, normalize } from "node:path";
const root = new URL("./", import.meta.url);
const mime = {".html":"text/html; charset=utf-8", ".js":"text/javascript", ".css":"text/css", ".wasm":"application/wasm"};
const manifest = JSON.parse(await readFile(new URL("patra-manifest.json", root), "utf8"));
const escapeHtml = value => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
const modules = new Map();
for (const route of manifest.routes) if (route.serverWasm) modules.set(route.path, await WebAssembly.compile(await readFile(new URL(route.serverWasm.slice(1), root))));
const routeFor = pathname => { const parts=pathname.split("/").filter(Boolean); for(const route of manifest.routes){const pattern=route.path.split("/").filter(Boolean);if(pattern.length!==parts.length)continue;let matches=true;const params={};for(let i=0;i<pattern.length;i++){const key=pattern[i].match(/^\[([^\]]+)\]$/);if(key)params[key[1]]=parts[i];else if(pattern[i]!==parts[i])matches=false}if(matches)return {route,params}}return null };
createServer(async (req,res)=>{try{const url=new URL(req.url,"http://localhost");if(url.pathname.startsWith("/__patra/rpc/")){res.writeHead(501,{"content-type":"application/json"});res.end(JSON.stringify({error:"Patra RPC is not available in this build"}));return}const match=routeFor(url.pathname);const route=match?.route;const module=route&&modules.get(route.path);if(module){const instance=await WebAssembly.instantiate(module,{});if(instance.exports._patra_json_abi_version?.()!==1)throw Error("Unsupported Patra Wasm ABI");instance.exports._patra_init?.()}let file=decodeURIComponent(url.pathname.slice(1));if(file==="")file="index.html";if(route&&route.path!=="/"&&!extname(file))file=route.path.slice(1)+"/index.html";if(!extname(file))file=file.replace(/\/?$/,"/")+"index.html";file=normalize(file);if(file.startsWith(".."))throw Error("bad path");let body=await readFile(new URL(file,root));if(match&&Object.keys(match.params).length){body=body.toString("utf8");for(const [name,value] of Object.entries(match.params))body=body.replaceAll("__PATRA_PARAM_"+name+"__",escapeHtml(value))}res.writeHead(200,{"content-type":mime[extname(file)]||"application/octet-stream"});res.end(body)}catch(error){console.error(error);res.writeHead(404);res.end("Not found")}}).listen(__PATRA_PORT__,()=>console.log("Patra on http://localhost:__PATRA_PORT__"));
`
	server = replace_all(server, "__PATRA_PORT__", config.port)
	return write_text(concat(out, "/server.mjs"), server)
}

build_vite_assets :: proc(root, out: string, config: Build_Config, routes: []Route) -> bool {
	input := strings.builder_make()
	strings.write_string(&input, "{")
	entry_count := 0
	for route, i in routes {
		if route.script_ts && !config.vite {
			fmt.eprintln("TypeScript in", route.source, "requires Vite. Run patra setup vite.")
			return false
		}
		if trim(route.script) == "" do continue
		if entry_count > 0 do strings.write_string(&input, ",")
		strings.write_string(&input, fmt.tprintf("route-%d: resolve(process.cwd(), %q)", i, path_join(path_join(out, ".patra/vite"), fmt.tprintf("route-%d.ts", i))))
		entry_count += 1
	}
	if config.tailwind == "Vite" {
		if entry_count > 0 do strings.write_string(&input, ",")
		style_entry := path_join(path_join(out, ".patra/vite"), "styles.js")
		if !write_text(style_entry, "import '../../src/input.css';\n") do return false
		strings.write_string(&input, fmt.tprintf("styles: resolve(process.cwd(), %q)", style_entry))
		entry_count += 1
	}
	if entry_count == 0 do return true
	b := strings.builder_make()
	strings.write_string(&b, "import { mergeConfig } from 'vite';\nimport { resolve } from 'node:path';\nimport userConfig from '../../vite.config.ts';\n")
	tailwind_plugin_in_user_config := false
	if config.tailwind == "Vite" {
		user_config_text, user_config_exists := read_text(path_join(root, "vite.config.ts"))
		tailwind_plugin_in_user_config = user_config_exists && strings.contains(user_config_text, "@tailwindcss/vite")
		if !tailwind_plugin_in_user_config do strings.write_string(&b, "import tailwindcss from '@tailwindcss/vite';\n")
	}
	strings.write_string(&b, "const baseConfig = typeof userConfig === 'function' ? await userConfig({ command: 'build', mode: 'production' }) : userConfig;\n")
	strings.write_string(&b, "export default mergeConfig(baseConfig, {\n")
	if config.tailwind == "Vite" && !tailwind_plugin_in_user_config do strings.write_string(&b, "  plugins: [tailwindcss()],\n")
	strings.write_string(&b, "  build: { outDir: resolve(process.cwd(), ")
	strings.write_string(&b, fmt.tprintf("%q", path_join(out, "assets")))
	strings.write_string(&b, "), emptyOutDir: false, rollupOptions: { input: ")
	strings.write_string(&b, strings.to_string(input))
	strings.write_string(&b, ", output: { entryFileNames: '[name].js', assetFileNames: (asset) => asset.name?.endsWith('.css') ? 'patra.css' : '[name][extname]' } } }\n});\n")
	config_path := path_join(path_join(out, ".patra"), "vite.config.mjs")
	if !write_text(config_path, strings.to_string(b)) do return false
	command := []string{"npx", "--no-install", "vite", "build", "--config", config_path}
	state, stdout, stderr, process_err := os.process_exec({command=command, working_dir=root}, context.allocator)
	if process_err != nil || state.exit_code != 0 {
		fmt.eprintln("Vite build failed. Check that Vite and selected npm packages are installed.")
		fmt.println(string(stderr)); fmt.println(string(stdout)); return false
	}
	return true
}

write_worker_runtime :: proc(out: string, routes: []Route) -> bool {
	b := strings.builder_make()
	strings.write_string(&b, "const serverModules = new Map([\n")
	for route, i in routes {
		if trim(route.server) == "" do continue
		strings.write_string(&b, fmt.tprintf("  [%s, wasm_%d],\n", json_string(route.url), i))
	}
	strings.write_string(&b, "]);\n")
	strings.write_string(&b, `const routeFor = pathname => { const parts=pathname.split("/").filter(Boolean); for(const [route] of serverModules){const pattern=route.split("/").filter(Boolean);if(pattern.length!==parts.length)continue;let matches=true;for(let i=0;i<pattern.length;i++)if(!/^\[[^\]]+\]$/.test(pattern[i])&&pattern[i]!==parts[i])matches=false;if(matches)return route}return null };
export default { async fetch(request, env) { const route=routeFor(new URL(request.url).pathname);const module=route&&serverModules.get(route);if(module){const instance=await WebAssembly.instantiate(module,{});if(instance.exports._patra_json_abi_version?.()!==1)throw Error("Unsupported Patra Wasm ABI");instance.exports._patra_init?.()}return env.ASSETS.fetch(request) } };
`)
	worker := strings.builder_make()
	for route, i in routes {
		if trim(route.server) == "" do continue
		strings.write_string(&worker, fmt.tprintf("import wasm_%d from \"./assets/server-%d.wasm\";\n", i, i))
	}
	strings.write_string(&worker, strings.to_string(b))
	return write_text(concat(out, "/_worker.js"), strings.to_string(worker))
}

build_project :: proc(root, output: string) -> bool {
	config, config_ok := read_config(concat(root, "/patra.config.odin"))
	if !config_ok {
		fmt.eprintln("Missing patra.config.odin in", root)
		return false
	}
	out := output
	if out == "" do out = concat(root, "/build")
	if os.remove_all(out) != nil && os.is_directory(out) {
		fmt.eprintln("Could not clear build output:", out)
		return false
	}
	if os.make_directory_all(concat(out, "/assets")) != nil {
		fmt.eprintln("Could not create build assets directory")
		return false
	}
	routes: [dynamic]Route
	routes_dir := path_join(root, "src/routes")
	if !read_routes(root, routes_dir, &routes) {
		fmt.eprintln("Could not read routes under", routes_dir)
		return false
	}
	if len(routes) == 0 {
		fmt.eprintln("No route .patra files found")
		return false
	}
	manifest := strings.builder_make()
	strings.write_string(&manifest, "{\"name\":")
	strings.write_string(&manifest, json_string(config.name))
	strings.write_string(&manifest, ",\"runtime\":\"")
	strings.write_string(&manifest, config.runtime)
	strings.write_string(&manifest, "\",\"mode\":\"")
	strings.write_string(&manifest, config.mode)
	strings.write_string(&manifest, "\",\"routes\":[")
	for route, i in routes {
		if route.script_ts && !config.vite {
			fmt.eprintln("TypeScript in", route.source, "requires Vite. Run patra setup vite.")
			return false
		}
		if i > 0 do strings.write_string(&manifest, ",")
		if !compile_wasm(root, out, route, i, "server", route.server) do return false
		if !compile_wasm(root, out, route, i, "client", route.client) do return false
		if trim(route.script) != "" && !config.vite {
			script_path := path_join(path_join(out, "assets"), fmt.tprintf("route-%d.js", i))
			if !write_text(script_path, script_with_handlers(route)) do return false
		}
		if config.vite && trim(route.script) != "" {
			entry_source := strings.builder_make()
			if config.tailwind == "Vite" do strings.write_string(&entry_source, "import '../../src/input.css';\n")
			strings.write_string(&entry_source, script_with_handlers(route))
			entry := path_join(path_join(path_join(out, ".patra"), "vite"), fmt.tprintf("route-%d.ts", i))
			if !write_text(entry, strings.to_string(entry_source)) do return false
		}
		server_wasm := "null"
		client_wasm := "null"
		if trim(route.server) != "" do server_wasm = fmt.tprintf("\"/assets/server-%d.wasm\"", i)
		if trim(route.client) != "" do client_wasm = fmt.tprintf("\"/assets/client-%d.wasm\"", i)
		strings.write_string(&manifest, "{\"path\":")
		strings.write_string(&manifest, json_string(route.url))
		strings.write_string(&manifest, ",\"serverWasm\":")
		strings.write_string(&manifest, server_wasm)
		strings.write_string(&manifest, ",\"clientWasm\":")
		strings.write_string(&manifest, client_wasm)
		strings.write_string(&manifest, "}")
		values: [dynamic]Value
		parse_odin_values(route.server, &values)
		parse_odin_values(route.client, &values)
		parse_script_values(route.script, &values)
		add_route_param_placeholders(route.url, &values)
		title := route.title
		if title == "" do title = config.name
		html := render_markup(route.markup, values[:])
		html = strings.trim_space(html)
		script_url := ""
		if trim(route.script) != "" do script_url = fmt.tprintf("/assets/route-%d.js", i)
		client_wasm_url := ""
		if trim(route.client) != "" do client_wasm_url = fmt.tprintf("/assets/client-%d.wasm", i)
		script_tag := ""
		if client_wasm_url != "" || script_url != "" do script_tag = fmt.tprintf(`<script defer src="/assets/patra.js" data-patra-client-wasm="%s" data-patra-script="%s"></script>`, client_wasm_url, script_url)
		page := render_page(route, html, title, config, script_tag)
		target := concat(out, "/index.html")
		if route.url != "/" {
			target = concat(concat(out, route.url), "/index.html")
			if os.make_directory_all(concat(out, route.url)) != nil do return false
		}
		if !write_text(target, page) {
			fmt.eprintln("Could not write generated page:", target)
			return false
		}
	}
	strings.write_string(&manifest, "]}")
	if !write_text(concat(out, "/patra-manifest.json"), strings.to_string(manifest)) {
		fmt.eprintln("Could not write Patra manifest")
		return false
	}
	if config.vite && !build_vite_assets(root, out, config, routes[:]) do return false
	if !write_runtime(out, config) {
		fmt.eprintln("Could not write runtime files")
		return false
	}
	_ = os.remove_all(path_join(out, ".patra"))
	if config.platform == "Vercel" && config.runtime == "Node" {
		vercel_entry := `import { readFile } from "node:fs/promises";
import { extname } from "node:path";
const mime = {".html":"text/html; charset=utf-8", ".js":"text/javascript", ".css":"text/css", ".wasm":"application/wasm"};
const manifest = JSON.parse(await readFile(new URL("../patra-manifest.json", import.meta.url), "utf8"));
const wasmModules = new Map();
for (const route of manifest.routes) if (route.serverWasm) wasmModules.set(route.path, await WebAssembly.compile(await readFile(new URL("../" + route.serverWasm.slice(1), import.meta.url))));
export default async function handler(req, res) {
  try {
    const url = new URL(req.url, "http://localhost");
    const parts = url.pathname.split("/").filter(Boolean);
    for (const route of manifest.routes) {
      const pattern = route.path.split("/").filter(Boolean);
      if (pattern.length !== parts.length) continue;
      let matches = true;
      for (let i = 0; i < pattern.length; i++) if (!/^\[[^\]]+\]$/.test(pattern[i]) && pattern[i] !== parts[i]) matches = false;
      const module = matches && wasmModules.get(route.path);
      if (module) { const instance = await WebAssembly.instantiate(module, {}); if (instance.exports._patra_json_abi_version?.() !== 1) throw new Error("Unsupported Patra Wasm ABI"); instance.exports._patra_init?.(); break; }
    }
    let file = decodeURIComponent(url.pathname.slice(1));
    if (file === "" || !extname(file)) file = file.replace(/\/?$/, "/") + "index.html";
    if (file.includes("..")) throw new Error("bad path");
    const body = await readFile(new URL("../" + file, import.meta.url));
    res.writeHead(200, {"content-type": mime[extname(file)] || "application/octet-stream"});
    res.end(body);
  } catch { res.writeHead(404); res.end("Not found"); }
}

`
		if !write_text(path_join(out, "api/index.mjs"), vercel_entry) do return false
	}
	if config.platform == "Cloudflare" && config.runtime == "Worker" {
		if !write_worker_runtime(out, routes[:]) do return false
	}
	if config.tailwind == "CLI" {
		command := []string{"tailwindcss", "-i", path_join(root, "src/input.css"), "-o", path_join(path_join(out, "assets"), "patra.css"), "--minify"}
		state, stdout, stderr, process_err := os.process_exec({command=command, working_dir=root}, context.allocator)
		if process_err != nil || state.exit_code != 0 {
			fmt.eprintln("Tailwind CLI is required. Install the standalone CLI: https://tailwindcss.com/docs/installation/tailwind-cli")
			fmt.println(string(stderr)); fmt.println(string(stdout)); return false
		}
	}
	fmt.println("Built", len(routes), "Patra routes for", config.name, "to", out)
	fmt.println("Runtime:", config.runtime, "Mode:", config.mode)
	return true
}

seo_tags :: proc(route: Route, title: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, fmt.tprintf("<meta property=\"og:title\" content=\"%s\">", escape_html(title)))
	for item in route.data {
		if item.name == "description" {
			value := escape_html(item.value)
			strings.write_string(&b, fmt.tprintf("<meta name=\"description\" content=\"%s\"><meta property=\"og:description\" content=\"%s\">", value, value))
		} else if item.name == "keywords" {
			strings.write_string(&b, fmt.tprintf("<meta name=\"keywords\" content=\"%s\">", escape_html(item.value)))
		} else if item.name == "author" {
			strings.write_string(&b, fmt.tprintf("<meta name=\"author\" content=\"%s\">", escape_html(item.value)))
		} else if item.name == "image" || item.name == "og:image" {
			strings.write_string(&b, fmt.tprintf("<meta property=\"og:image\" content=\"%s\"><meta name=\"twitter:card\" content=\"summary_large_image\">", escape_html(item.value)))
		} else if item.name == "robots" {
			strings.write_string(&b, fmt.tprintf("<meta name=\"robots\" content=\"%s\">", escape_html(item.value)))
		}
	}
	return strings.to_string(b)
}

script_with_handlers :: proc(route: Route) -> string {
	b := strings.builder_make()
	strings.write_string(&b, route.script)
	strings.write_string(&b, "\n globalThis.PatraScripts ??= {};\n")
	attributes := [2]string{"onclick={", "onsubmit={"}
	for attribute in attributes {
		cursor := 0
		for cursor < len(route.markup) {
			i := strings.index(route.markup[cursor:], attribute)
			if i < 0 do break
			i += cursor + len(attribute)
			end := strings.index(route.markup[i:], "}")
			if end < 0 do break
			name := trim(route.markup[i:i+end])
			valid := name != ""
			for c, j in name {
				if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' || (j > 0 && c >= '0' && c <= '9')) { valid = false; break }
			}
			if valid do strings.write_string(&b, fmt.tprintf("globalThis.PatraScripts[%q] = %s;\n", name, name))
			cursor = i + end + 1
		}
	}
	return strings.to_string(b)
}

render_page :: proc(route: Route, markup, title: string, config: Build_Config, script_tag: string) -> string {
	seo_title := fmt.tprintf("<title>%s</title>", escape_html(title))
	seo := seo_tags(route, title)
	if strings.contains(markup, "</head>") {
		head := seo
		if config.tailwind != "None" && !strings.contains(markup, "patra.css") do head = fmt.tprintf("<link rel=\"stylesheet\" href=\"/assets/patra.css\">%s", head)
		if trim(route.style) != "" do head = fmt.tprintf("%s<style>%s</style>", head, route.style)
		page := markup
		if strings.contains(page, "<title>") && strings.contains(page, "</title>") {
			start := strings.index(page, "<title>")
			end := strings.index(page[start:], "</title>")
			if end >= 0 {
				end += start + len("</title>")
				page, _ = strings.concatenate({page[:start], seo_title, page[end:]})
			}
		} else {
			head = fmt.tprintf("%s%s", seo_title, head)
		}
		page, _ = strings.replace_all(page, "</head>", fmt.tprintf("%s</head>", head))
		page, _ = strings.replace_all(page, "</body>", fmt.tprintf("%s</body>", script_tag))
		return page
	}
	return fmt.tprintf(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">%s%s<style>%s</style></head><body>%s%s</body></html>`, seo_title, seo, route.style, markup, script_tag)
}
