const blockPattern = /(^---\r?\n[\s\S]*?\r?\n---)|<odin\s+(server|client)\s*>([\s\S]*?)<\/odin>|<script\b([^>]*)>([\s\S]*?)<\/script>|<style\b([^>]*)>([\s\S]*?)<\/style>/gm;

function blockLanguage(kind, attributes = "") {
  if (kind === "frontmatter") return "yaml";
  if (kind === "server" || kind === "client") return "odin";
  if (kind === "style") return "css";
  const match = attributes.match(/\blang\s*=\s*["']?(typescript|javascript|ts|js)["']?/i);
  if (!match) return "javascript";
  return /^(ts|typescript)$/i.test(match[1]) ? "typescript" : "javascript";
}

export function parsePatra(text) {
  const regions = [];
  let cursor = 0;
  blockPattern.lastIndex = 0;
  for (const match of text.matchAll(blockPattern)) {
    const start = match.index;
    if (start > cursor && text.slice(cursor, start).trim()) {
      regions.push({ kind: "html", language: "html", start: cursor, end: start });
    }

    let kind;
    let bodyStart;
    let bodyEnd;
    let attributes = "";
    if (match[1]) {
      kind = "frontmatter";
      bodyStart = start + match[0].indexOf("\n") + 1;
      bodyEnd = start + match[0].lastIndexOf("\n---");
      if (text[bodyEnd - 1] === "\r") bodyEnd--;
    } else if (match[2]) {
      kind = match[2];
      bodyStart = start + match[0].indexOf(">") + 1;
      bodyEnd = start + match[0].lastIndexOf("</odin>");
    } else if (match[4] !== undefined) {
      kind = "script";
      attributes = match[4];
      bodyStart = start + match[0].indexOf(">") + 1;
      bodyEnd = start + match[0].lastIndexOf("</script>");
    } else {
      kind = "style";
      attributes = match[6] ?? "";
      bodyStart = start + match[0].indexOf(">") + 1;
      bodyEnd = start + match[0].lastIndexOf("</style>");
    }

    regions.push({
      kind,
      language: blockLanguage(kind, attributes),
      start: bodyStart,
      end: bodyEnd,
      attributes,
    });
    cursor = start + match[0].length;
  }
  if (cursor < text.length && text.slice(cursor).trim()) {
    regions.push({ kind: "html", language: "html", start: cursor, end: text.length });
  }
  return regions.filter(region => region.end > region.start);
}

export function maskOutside(text, start, end) {
  // Preserve UTF-16 offsets and line breaks so LSP positions map back directly.
  return text.slice(0, start).replace(/[^\r\n]/g, " ")
    + text.slice(start, end)
    + text.slice(end).replace(/[^\r\n]/g, " ");
}

export function findYamlSlashComments(text, regions) {
  const ranges = [];
  for (const region of regions.filter(item => item.kind === "frontmatter")) {
    const body = text.slice(region.start, region.end);
    let offset = region.start;
    for (const line of body.split(/\r?\n/)) {
      const match = line.match(/^(\s*)\/\/.*$/);
      if (match) ranges.push({ start: offset + match[1].length, end: offset + line.length });
      offset += line.length + 1;
    }
  }
  return ranges;
}

const odinTsTypes = new Map([
  ["string", "string"], ["bool", "boolean"], ["int", "number"], ["uint", "number"],
  ["i8", "number"], ["i16", "number"], ["i32", "number"], ["i64", "number"],
  ["u8", "number"], ["u16", "number"], ["u32", "number"], ["u64", "number"],
  ["f16", "number"], ["f32", "number"], ["f64", "number"], ["rune", "string"],
]);

function mapType(type) {
  const bare = type.trim().replace(/^\^/, "");
  if (odinTsTypes.has(bare)) return odinTsTypes.get(bare);
  if (/^\[\]/.test(bare)) return `${mapType(bare.slice(2))}[]`;
  if (bare.startsWith("schema.")) return bare.split(".").at(-1);
  if (bare.includes(".")) return "unknown";
  return bare || "unknown";
}

function isTopLevelAt(source, target) {
  let depth = 0;
  let quote = "";
  let lineComment = false;
  let blockComment = false;
  let escaped = false;
  for (let index = 0; index < target; index++) {
    const char = source[index];
    const next = source[index + 1];
    if (lineComment) {
      if (char === "\n") lineComment = false;
    } else if (blockComment) {
      if (char === "*" && next === "/") { blockComment = false; index++; }
    } else if (quote) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === quote) quote = "";
    } else if (char === "/" && next === "/") { lineComment = true; index++; }
    else if (char === "/" && next === "*") { blockComment = true; index++; }
    else if (char === "\"" || char === "'" || char === "`") quote = char;
    else if (char === "{") depth++;
    else if (char === "}") depth = Math.max(0, depth - 1);
  }
  return depth === 0;
}

export function extractSharedSymbols(text, regions) {
  const symbols = [];
  for (const region of regions.filter(item => ["server", "client"].includes(item.kind))) {
    const body = text.slice(region.start, region.end);
    const lines = body.split(/\r?\n/);
    let offset = region.start;
    let braceDepth = 0;
    let previousLine = "";
    for (const line of lines) {
      const cssAnnotation = previousLine.match(/\/\/\s*@patra\s+css(?:\s+(--[\w-]+))?\s*$/);
      const variable = braceDepth === 0 && line.match(/^\s*([A-Za-z_]\w*)\s*:\s*([\w\[\]^]+)(?:\s*=.*)?\s*$/);
      const declaration = braceDepth === 0 && line.match(/^\s*([A-Za-z_]\w*)\s*::\s*(.+?)\s*$/);
      if (variable && variable[1][0] !== "_") {
        symbols.push({
          name: variable[1],
          kind: "variable",
          sourceKind: region.kind,
          cssExport: Boolean(cssAnnotation),
          cssName: cssAnnotation?.[1] ?? `--${variable[1].replace(/[A-Z]/g, letter => `-${letter.toLowerCase()}`)}`,
          odinType: variable[2],
          tsType: mapType(variable[2]),
          start: offset + line.indexOf(variable[1]),
          end: offset + line.indexOf(variable[1]) + variable[1].length,
        });
      } else if (declaration && declaration[1][0] !== "_") {
        const rhs = declaration[2];
        const proc = rhs.match(/proc\s*\(([^)]*)\)\s*(?:->\s*([\w.\[\]^]+))?/);
        const struct = /\b(struct|union|enum)\b/.exec(rhs);
        let tsType = "unknown";
        let odinStub;
        let kind = "constant";
        if (proc) {
          kind = "function";
          const parameters = proc[1].split(",").filter(Boolean).map((item, index) => {
            const parsed = item.trim().match(/([A-Za-z_]\w*)\s*:\s*([\w\[\]^]+)/);
            return parsed ? `${parsed[1]}: ${mapType(parsed[2])}` : `arg${index}: unknown`;
          });
          tsType = `(${parameters.join(", ")}) => ${mapType(proc[2] ?? "void")}`;
          odinStub = `${declaration[1]}: proc(${proc[1]})${proc[2] ? ` -> ${proc[2]}` : ""}`;
        } else if (struct) {
          kind = "type";
          const tail = body.slice(offset - region.start + line.indexOf(declaration[1]));
          const open = tail.indexOf("{");
          let depth = 0;
          let close = -1;
          for (let index = open; open >= 0 && index < tail.length; index++) {
            if (tail[index] === "{") depth++;
            else if (tail[index] === "}" && --depth === 0) { close = index; break; }
          }
          const declarationText = close >= 0 ? tail.slice(0, close + 1) : `${declaration[1]} :: ${struct[1]} {}`;
          const fields = [...declarationText.matchAll(/^\s*([A-Za-z_]\w*)\s*:\s*([\w.\[\]^]+).*$/gm)]
            .filter(field => field[1] !== declaration[1])
            .map(field => `${field[1]}: ${mapType(field[2])};`);
          tsType = fields.length ? `{ ${fields.join(" ")} }` : "Record<string, unknown>";
          odinStub = declarationText.replace(/(^\s*[A-Za-z_]\w*\s*:\s*)([\w.]+)/gm, (_match, prefix, type) => `${prefix}${type.includes(".") ? "any" : type}`);
        } else {
          const literal = rhs.match(/^\s*("(?:[^"\\]|\\.)*"|true|false|-?\d+(?:\.\d+)?)/);
          tsType = literal?.[1].startsWith('"') ? "string" : literal?.[1] === "true" || literal?.[1] === "false" ? "boolean" : literal ? "number" : "unknown";
          odinStub = `${declaration[1]}: ${tsType === "string" ? "string" : tsType === "boolean" ? "bool" : tsType === "number" ? "int" : "any"}`;
        }
        if (region.kind === "client" || kind === "type" || kind === "constant") symbols.push({
          name: declaration[1], kind: kind === "constant" ? "value" : kind, sourceKind: region.kind, cssExport: Boolean(cssAnnotation), cssName: cssAnnotation?.[1] ?? `--${declaration[1].replace(/[A-Z]/g, letter => `-${letter.toLowerCase()}`)}`, odinType: "", tsType, odinStub,
          start: offset + line.indexOf(declaration[1]),
          end: offset + line.indexOf(declaration[1]) + declaration[1].length,
        });
      }
      const withoutStrings = line.replace(/"(?:[^"\\]|\\.)*"|`[^`]*`|\/\/.*$/, "");
      braceDepth += (withoutStrings.match(/{/g) ?? []).length - (withoutStrings.match(/}/g) ?? []).length;
      offset += line.length + 1;
      previousLine = line;
    }
  }
  for (const region of regions.filter(item => item.kind === "script")) {
    const body = text.slice(region.start, region.end);
    const pattern = /\b(?:export\s+)?(?:const|let|var|function|class|interface|type|enum)\s+([A-Za-z_$][\w$]*)/g;
    for (const match of body.matchAll(pattern)) {
      if (!isTopLevelAt(body, match.index)) continue;
      const before = body.slice(0, match.index).trimEnd().split(/\r?\n/).at(-1) ?? "";
      const cssAnnotation = before.match(/\/\/\s*@patra\s+css(?:\s+(--[\w-]+))?\s*$/);
      symbols.push({ name: match[1], kind: /function/.test(match[0]) ? "function" : /class|interface|type|enum/.test(match[0]) ? "type" : "value", tsType: "unknown", odinType: "", sourceKind: "script", cssExport: Boolean(cssAnnotation), cssName: cssAnnotation?.[1] ?? `--${match[1].replace(/[A-Z]/g, letter => `-${letter.toLowerCase()}`)}`, start: region.start + match.index + match[0].lastIndexOf(match[1]), end: region.start + match.index + match[0].lastIndexOf(match[1]) + match[1].length });
    }
  }
  for (const region of regions.filter(item => item.kind === "html")) {
    const body = text.slice(region.start, region.end);
    for (const match of body.matchAll(/\b(?:id|class)\s*=\s*(["'])(.*?)\1/g)) {
      const names = match[0].startsWith("id") ? [match[2]] : match[2].split(/\s+/).filter(Boolean);
      for (const name of names) symbols.push({ name, kind: match[0].startsWith("id") ? "html-id" : "html-class", sourceKind: "html", start: region.start + match.index, end: region.start + match.index + match[0].length });
    }
  }
  return symbols;
}

export function extractRpcRoutes(text, regions) {
  const server = regions.find(region => region.kind === "server");
  if (!server) return [];
  const body = text.slice(server.start, server.end);
  const procedures = new Map();
  for (const match of body.matchAll(/^\s*([A-Za-z_]\w*)\s*::\s*proc\(([^)]*)\)\s*(?:->\s*([\w.\[\]^]+))?/gm)) {
    const params = match[2].split(",").map(item => item.trim()).filter(Boolean)
      .filter(item => !/^ctx\s*:/.test(item))
      .map((item, index) => {
        const parameter = item.match(/^([A-Za-z_]\w*)\s*:\s*([\w.\[\]^]+)/);
        return parameter ? { name: parameter[1], type: mapType(parameter[2]) } : { name: `arg${index}`, type: "unknown" };
      });
    procedures.set(match[1], { params, result: mapType(match[3] ?? "void") });
  }
  const routes = [];
  for (const match of body.matchAll(/\brpc\.([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*\(\s*([A-Za-z_]\w*)\s*\)/g)) {
    const proc = procedures.get(match[2]) ?? { params: [], result: "unknown" };
    routes.push({
      path: match[1].split("."),
      operation: proc.params.length ? "mutation" : "query",
      params: proc.params,
      result: proc.result,
      handler: match[2],
      start: server.start + match.index,
      end: server.start + match.index + match[0].length,
    });
  }
  return routes;
}

export function visibleSharedSymbols(regionKind, symbols) {
  return symbols.filter(symbol => {
    if (regionKind === "client") return symbol.sourceKind === "server" && symbol.kind === "type";
    if (regionKind === "script") return (symbol.sourceKind === "server" && symbol.kind === "type") || symbol.sourceKind === "client";
    if (regionKind === "frontmatter") return symbol.sourceKind === "server";
    if (regionKind === "html") return ["server", "client", "script"].includes(symbol.sourceKind);
    if (regionKind === "style") return symbol.kind.startsWith("html-") || (["client", "script"].includes(symbol.sourceKind) && symbol.cssExport && symbol.kind !== "type");
    return false;
  });
}

export function appendSharedDeclarations(language, source, symbols, rpcRoutes = []) {
  const types = symbols.filter(item => item.kind === "type");
  if (!types.length && !(["typescript", "javascript"].includes(language) && rpcRoutes.length)) return source;
  const separator = source.endsWith("\n") ? "\n" : "\n\n";
  if (language === "odin") {
    return source + separator + "// Patra shared type declarations\n" + types.map(item => item.odinStub).join("\n") + "\n";
  }
  if (language === "typescript") {
    const declarations = types.map(item => `    type ${item.name} = ${item.tsType ?? "unknown"};`).join("\n");
    const rpcTree = {};
    for (const route of rpcRoutes) {
      let node = rpcTree;
      for (const part of route.path) node = node[part] ??= {};
      node[route.operation] = `(${route.params.map(param => `${param.name}: ${param.type}`).join(", ")}) => Promise<${route.result}>`;
    }
    const render = node => `{ ${Object.entries(node).map(([name, value]) => `${name}: ${typeof value === "string" ? value : render(value)}`).join("; ")} }`;
    const rpc = rpcRoutes.length ? `\n    const rpc: ${render(rpcTree)};` : "";
    return `${source}${separator}declare global {\n${declarations}${rpc}\n}\nexport {};\n`;
  }
  if (language === "javascript") {
    const declarations = types.map(item => `/** @typedef {${item.tsType ?? "unknown"}} ${item.name} */`).join("\n");
    const rpcTree = {};
    for (const route of rpcRoutes) {
      let node = rpcTree;
      for (const part of route.path) node = node[part] ??= {};
      node[route.operation] = `(${route.params.map(param => `${param.name}: ${param.type}`).join(", ")}) => Promise<${route.result}>`;
    }
    const render = node => `{ ${Object.entries(node).map(([name, value]) => {
      if (typeof value !== "string") return `${name}: ${render(value)}`;
      const signature = value.match(/^\((.*?)\) => Promise<(.+)>$/);
      const jsParams = signature?.[1].split(", ").filter(Boolean).map(param => param.split(": ").at(-1)).join(", ");
      const functionType = signature ? `function(${jsParams}): Promise<${signature[2]}>` : "Function";
      return `${name}: ${functionType}`;
    }).join(", ")} }`;
    const hasRpcBinding = /\b(?:import\s+.*\brpc\b|(?:const|let|var|function|class)\s+rpc\b)/.test(source);
    const rpc = rpcRoutes.length && !hasRpcBinding ? `/** @type {${render(rpcTree)}} */\nvar rpc;\n` : "";
    return `${source}${separator}${declarations}\n${rpc}`;
  }
  return source;
}
