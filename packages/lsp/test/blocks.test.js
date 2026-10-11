import test from "node:test";
import assert from "node:assert/strict";
import { appendSharedDeclarations, extractRpcRoutes, extractSharedSymbols, findYamlSlashComments, maskOutside, parsePatra, visibleSharedSymbols } from "../src/blocks.js";

const sample = `---\ntitle: demo\n---\n<odin server>\ndemo: string = "test"\nPerson :: struct {\n  name: string\n}\n</odin>\n<odin client>\nprint(demo)\n</odin>\n<script lang="ts">\nconst newDemo = demo + "new"\n</script>\n<div>{demo}</div>\n<style>\nbody { color: red }\n</style>\n`;

test("finds each Patra language region and its source range", () => {
  const regions = parsePatra(sample);
  assert.deepEqual(regions.map(region => region.language), ["yaml", "odin", "odin", "typescript", "html", "css"]);
  assert.equal(sample.slice(regions[1].start, regions[1].end).trim(), 'demo: string = "test"\nPerson :: struct {\n  name: string\n}');
});

test("masks other blocks without changing LSP positions", () => {
  const region = parsePatra(sample).find(item => item.kind === "script");
  const projected = maskOutside(sample, region.start, region.end);
  assert.equal(projected.length, sample.length);
  assert.equal(projected.split("\n").length, sample.split("\n").length);
  assert.equal(projected.includes('const newDemo = demo + "new"'), true);
});

test("shares server type declarations without leaking server values", () => {
  const regions = parsePatra(sample);
  const symbols = extractSharedSymbols(sample, regions);
  assert.deepEqual(symbols.map(symbol => symbol.name), ["demo", "Person", "newDemo"]);
  const script = regions.find(region => region.kind === "script");
  const client = regions.find(region => region.kind === "client");
  assert.match(appendSharedDeclarations("typescript", sample.slice(script.start, script.end), symbols), /type Person = \{ name: string; \}/);
  assert.doesNotMatch(appendSharedDeclarations("typescript", sample.slice(script.start, script.end), symbols), /(?:const|var) demo\s*:/);
  assert.match(appendSharedDeclarations("odin", sample.slice(client.start, client.end), symbols), /Person :: struct/);
  assert.doesNotMatch(appendSharedDeclarations("odin", sample.slice(client.start, client.end), symbols), /demo: string/);
});

test("enforces server type-only access and annotated CSS exports", () => {
  const source = `<odin server>\nSecret :: struct {\n  value: int\n}\nsecretValue: string = "private"\nfetch :: proc(ctx: ^rpc.Context, id: int) -> Secret { return {} }\nrpc.demo.fetch(fetch)\n</odin>\n<odin client>\n// @patra css --accent\naccent: string = "red"\nclientValue :: true\n</odin>\n<script lang="ts">\n// @patra css\nconst spacing = 4\nconst localOnly = 1\n</script>\n<div id="hero">{secretValue}</div>\n<style>\n</style>`;
  const regions = parsePatra(source);
  const symbols = extractSharedSymbols(source, regions);
  const rpcRoutes = extractRpcRoutes(source, regions);
  const serverValue = symbols.find(item => item.name === "secretValue");
  const serverType = symbols.find(item => item.name === "Secret");
  assert.deepEqual(visibleSharedSymbols("client", symbols), [serverType]);
  assert.equal(visibleSharedSymbols("script", symbols).some(item => item.name === "secretValue"), false);
  assert.equal(visibleSharedSymbols("frontmatter", symbols).includes(serverValue), true);
  assert.equal(visibleSharedSymbols("html", symbols).includes(serverValue), true);
  assert.deepEqual(visibleSharedSymbols("style", symbols).map(item => item.name), ["accent", "spacing", "hero"]);
  assert.deepEqual(rpcRoutes.map(route => [route.path.join("."), route.operation, route.params[0].type, route.result]), [["demo.fetch", "mutation", "number", "Secret"]]);
  const script = regions.find(region => region.kind === "script");
  const scriptText = appendSharedDeclarations("typescript", source.slice(script.start, script.end), visibleSharedSymbols("script", symbols), rpcRoutes);
  assert.match(scriptText, /const rpc: .*mutation: \(id: number\) => Promise<Secret>/);
  assert.doesNotMatch(scriptText, /secretValue/);
  const jsText = appendSharedDeclarations("javascript", "", visibleSharedSymbols("script", symbols), rpcRoutes);
  assert.match(jsText, /var rpc;/);
  assert.match(jsText, /mutation: function\(number\): Promise<Secret>/);
});

test("collects Odin and script exports plus HTML selectors for downstream blocks", () => {
  const source = `<odin server>serverValue: int = 1</odin>\n<odin client>clientValue :: true</odin>\n<script lang="js">function scriptValue() { const localOnly = 1 }\nconst scriptConst = 1</script>\n<div id="hero" class="card wide">{serverValue}</div>\n<style>.card { color: red }</style>`;
  const symbols = extractSharedSymbols(source, parsePatra(source));
  assert.deepEqual(symbols.map(symbol => symbol.name), ["serverValue", "clientValue", "scriptValue", "scriptConst", "hero", "card", "wide"]);
});

test("rejects slash-style comments in YAML frontmatter", () => {
  const source = `---\n# valid comment\n// invalid comment\ntitle: demo\n---\n`;
  const ranges = findYamlSlashComments(source, parsePatra(source));
  assert.equal(ranges.length, 1);
  assert.equal(source.slice(ranges[0].start, ranges[0].end), "// invalid comment");
});
