import { spawn } from "node:child_process";
import { createMessageConnection, StreamMessageReader, StreamMessageWriter } from "vscode-jsonrpc/node.js";
import {
  createConnection,
  ProposedFeatures,
  TextDocumentSyncKind,
  TextDocument,
} from "vscode-languageserver/node.js";
import { appendSharedDeclarations, extractRpcRoutes, extractSharedSymbols, findYamlSlashComments, maskOutside, parsePatra, visibleSharedSymbols } from "./blocks.js";

const connection = createConnection(ProposedFeatures.all);
const states = new Map();
const children = new Map();
const virtualDocuments = new Map();
let initializeParams;

const definitions = {
  odin: { command: process.env.PATRA_OLS ?? "ols", args: [] },
  yaml: { command: process.env.PATRA_YAML_LSP ?? "yaml-language-server", args: ["--stdio"] },
  html: { command: process.env.PATRA_HTML_LSP ?? "vscode-html-language-server", args: ["--stdio"] },
  css: { command: process.env.PATRA_CSS_LSP ?? "vscode-css-language-server", args: ["--stdio"] },
  typescript: { command: process.env.PATRA_TS_LSP ?? "typescript-language-server", args: ["--stdio"] },
};

const extension = {
  odin: "odin",
  yaml: "yaml",
  html: "html",
  css: "css",
  javascript: "js",
  typescript: "ts",
};

function serverKey(language) {
  return language === "javascript" || language === "typescript" ? "typescript" : language;
}

function languageId(language) {
  return language === "javascript" ? "javascript" : language;
}

function makeVirtualUri(hostUri, region, index) {
  const url = new URL(hostUri);
  url.pathname += `.patra-${index}.${extension[region.language]}`;
  url.search = "";
  url.hash = "";
  return url.toString();
}

function mapVirtualResult(value) {
  if (Array.isArray(value)) return value.map(mapVirtualResult);
  if (!value || typeof value !== "object") return value;
  const mapped = { ...value };
  if (typeof mapped.uri === "string" && virtualDocuments.has(mapped.uri)) {
    mapped.uri = virtualDocuments.get(mapped.uri).hostUri;
  }
  if (typeof mapped.targetUri === "string" && virtualDocuments.has(mapped.targetUri)) {
    mapped.targetUri = virtualDocuments.get(mapped.targetUri).hostUri;
  }
  for (const [key, child] of Object.entries(mapped)) {
    if (child && typeof child === "object") mapped[key] = mapVirtualResult(child);
  }
  return mapped;
}

function sendDiagnostics(hostUri) {
  const state = states.get(hostUri);
  if (!state) return;
  const diagnostics = [];
  for (const region of state.virtuals) {
    const childDiagnostics = state.diagnostics.get(region.uri) ?? [];
    for (const diagnostic of childDiagnostics) {
      const offset = state.document.offsetAt(diagnostic.range.start);
      if (offset >= region.start && offset <= region.end) {
        diagnostics.push({ ...diagnostic, source: diagnostic.source ?? `patra:${region.language}` });
      }
    }
  }
  for (const range of findYamlSlashComments(state.text, state.virtuals)) {
    diagnostics.push({
      range: { start: state.document.positionAt(range.start), end: state.document.positionAt(range.end) },
      severity: 1,
      source: "patra",
      message: "YAML comments use #, not //.",
    });
  }
  connection.sendNotification("textDocument/publishDiagnostics", {
    uri: hostUri,
    version: state.version,
    diagnostics,
  });
}

function addChildHandlers(child) {
  child.connection.onNotification("textDocument/publishDiagnostics", params => {
    const virtual = virtualDocuments.get(params.uri);
    if (!virtual) return;
    const state = states.get(virtual.hostUri);
    if (!state) return;
    state.diagnostics.set(params.uri, params.diagnostics ?? []);
    sendDiagnostics(virtual.hostUri);
  });

  child.connection.onRequest("workspace/configuration", params =>
    (params.items ?? []).map(() => null));
  child.connection.onRequest("workspace/workspaceFolders", () => initializeParams?.workspaceFolders ?? null);
  child.connection.onRequest("window/workDoneProgress/create", () => null);
  child.connection.onRequest("client/registerCapability", () => null);
  child.connection.onRequest("workspace/applyEdit", () => ({ applied: false }));
}

async function getChild(language) {
  const key = serverKey(language);
  if (children.has(key)) return children.get(key);

  const promise = new Promise((resolve, reject) => {
    const definition = definitions[key];
    const childProcess = spawn(definition.command, definition.args, {
      cwd: initializeParams?.rootUri ? new URL(initializeParams.rootUri).pathname : process.cwd(),
      stdio: ["pipe", "pipe", "pipe"],
    });
    childProcess.once("error", error => reject(new Error(`${definition.command} could not start: ${error.message}`)));
    childProcess.stderr.on("data", chunk => {
      const message = chunk.toString().trim();
      if (message) connection.console.debug(`[${key}] ${message}`);
    });

    const childConnection = createMessageConnection(
      new StreamMessageReader(childProcess.stdout),
      new StreamMessageWriter(childProcess.stdin),
    );
    const child = { process: childProcess, connection: childConnection, open: new Set() };
    addChildHandlers(child);
    childConnection.listen();
    childConnection.sendRequest("initialize", {
      processId: initializeParams?.processId ?? null,
      clientInfo: { name: "patra-lsp", version: "0.1.0" },
      rootUri: initializeParams?.rootUri ?? null,
      rootPath: initializeParams?.rootPath ?? null,
      workspaceFolders: initializeParams?.workspaceFolders ?? null,
      capabilities: initializeParams?.capabilities ?? {},
      initializationOptions: initializeParams?.initializationOptions ?? null,
      trace: "off",
    }).then(() => {
      childConnection.sendNotification("initialized", {});
      resolve(child);
    }, reject);
  });
  children.set(key, promise);
  try {
    return await promise;
  } catch (error) {
    children.delete(key);
    throw error;
  }
}

function visibleSymbols(region, symbols) {
  return visibleSharedSymbols(region.kind, symbols);
}

function virtualText(source, region, symbols, rpcRoutes) {
  let projected = maskOutside(source, region.start, region.end);
  const visible = visibleSymbols(region, symbols);
  if (region.kind === "client") projected = appendSharedDeclarations("odin", projected, visible);
  if (region.kind === "script") projected = appendSharedDeclarations(region.language, projected, visible, rpcRoutes);
  if (region.kind === "style") {
    const cssProperties = visible.filter(symbol => symbol.cssExport && symbol.cssName).map(symbol => `  ${symbol.cssName}: initial;`);
    if (cssProperties.length) projected += `\n\n:root {\n${cssProperties.join("\n")}\n}\n`;
  }
  return projected;
}

async function closeVirtual(state, region) {
  virtualDocuments.delete(region.uri);
  state.diagnostics.delete(region.uri);
  const childPromise = children.get(serverKey(region.language));
  if (!childPromise) return;
  try {
    const child = await childPromise;
    child.connection.sendNotification("textDocument/didClose", { textDocument: { uri: region.uri } });
    child.open.delete(region.uri);
  } catch { }
}

async function openVirtual(state, region) {
  try {
    const child = await getChild(region.language);
    virtualDocuments.set(region.uri, { hostUri: state.uri, region });
    state.diagnostics.set(region.uri, []);
    child.connection.sendNotification("textDocument/didOpen", {
      textDocument: {
        uri: region.uri,
        languageId: languageId(region.language),
        version: state.version,
        text: region.text,
      },
    });
    child.open.add(region.uri);
  } catch (error) {
    connection.console.warn(error.message);
  }
}

async function updateDocument(uri, text, version, opening = false) {
  const previous = states.get(uri);
  if (previous) await Promise.all(previous.virtuals.map(region => closeVirtual(previous, region)));

  const document = TextDocument.create(uri, "patra", version, text);
  const regions = parsePatra(text);
  const symbols = extractSharedSymbols(text, regions);
  const rpcRoutes = extractRpcRoutes(text, regions);
  const state = { uri, text, version, document, symbols, rpcRoutes, diagnostics: new Map(), virtuals: [] };
  regions.forEach((region, index) => {
    region.uri = makeVirtualUri(uri, region, index);
    region.text = virtualText(text, region, symbols, rpcRoutes);
    state.virtuals.push(region);
  });
  states.set(uri, state);
  await Promise.all(state.virtuals.map(region => openVirtual(state, region)));
  sendDiagnostics(uri);
}

connection.onInitialize(params => {
  initializeParams = params;
  return {
    capabilities: {
      textDocumentSync: { openClose: true, change: TextDocumentSyncKind.Full, save: { includeText: false } },
      hoverProvider: true,
      completionProvider: { triggerCharacters: [".", "{", ":"] },
      definitionProvider: true,
      referencesProvider: true,
      implementationProvider: true,
      typeDefinitionProvider: true,
      renameProvider: { prepareProvider: false },
      signatureHelpProvider: { triggerCharacters: ["(", ","] },
      documentSymbolProvider: true,
      documentHighlightProvider: true,
      codeActionProvider: true,
      documentFormattingProvider: true,
      documentRangeFormattingProvider: true,
    },
    serverInfo: { name: "patra-lsp", version: "0.1.0" },
  };
});

connection.onInitialized(() => connection.console.info("Patra LSP ready"));

connection.onDidOpenTextDocument(params => {
  void updateDocument(params.textDocument.uri, params.textDocument.text, params.textDocument.version, true);
});

connection.onDidChangeTextDocument(params => {
  const state = states.get(params.textDocument.uri);
  if (!state) return;
  const change = params.contentChanges.at(-1);
  if (change?.text !== undefined) {
    void updateDocument(params.textDocument.uri, change.text, params.textDocument.version);
  }
});

connection.onDidCloseTextDocument(params => {
  const state = states.get(params.textDocument.uri);
  if (!state) return;
  void Promise.all(state.virtuals.map(region => closeVirtual(state, region))).then(() => {
    states.delete(params.textDocument.uri);
    connection.sendNotification("textDocument/publishDiagnostics", { uri: params.textDocument.uri, diagnostics: [] });
  });
});

connection.onDidSaveTextDocument(params => {
  const state = states.get(params.textDocument.uri);
  if (!state) return;
  for (const region of state.virtuals) {
    const childPromise = children.get(serverKey(region.language));
    childPromise?.then(child => child.connection.sendNotification("textDocument/didSave", {
      textDocument: { uri: region.uri },
      text: region.text,
    })).catch(() => {});
  }
});

function regionAt(params) {
  const state = states.get(params.textDocument?.uri);
  if (!state) return null;
  const position = params.position ?? params.range?.start;
  if (!position) return null;
  const offset = state.document.offsetAt(position);
  const region = state.virtuals.find(item => offset >= item.start && offset <= item.end);
  return region ? { state, region, offset } : null;
}

function findSharedSymbol(state, region, offset) {
  const visible = visibleSymbols(region, state.symbols);
  const before = state.text.slice(0, offset);
  const after = state.text.slice(offset);
  const left = before.match(/[A-Za-z_$][\w$]*$/)?.[0] ?? "";
  const right = after.match(/^[\w$]*/)?.[0] ?? "";
  const name = left + right;
  return visible.find(item => item.name === name || (region.kind === "style" && item.cssName === `--${name}`)) ?? null;
}

function findRpcRouteAt(state, region, offset) {
  if (!["client", "script"].includes(region.kind)) return null;
  const before = state.text.slice(region.start, offset);
  const after = state.text.slice(offset);
  const left = before.match(/\brpc(?:\.[A-Za-z_$][\w$]*)*$/)?.[0] ?? "";
  const right = after.match(/^(?:\.[A-Za-z_$][\w$]*)*/)?.[0] ?? "";
  const path = `${left}${right}`.replace(/^rpc\.?/, "").replace(/\.(?:query|mutation)$/, "").split(".").filter(Boolean).join(".");
  return state.rpcRoutes.find(route => route.path.join(".") === path) ?? null;
}

function addSymbolCompletions(result, state, region) {
  const items = visibleSymbols(region, state.symbols).map(symbol => ({
    label: region.kind === "style" && symbol.kind === "html-class" ? `.${symbol.name}`
      : region.kind === "style" && symbol.kind === "html-id" ? `#${symbol.name}`
      : region.kind === "style" && symbol.cssExport ? symbol.cssName : symbol.name,
    kind: symbol.kind === "function" ? 3 : symbol.kind === "type" ? 7 : symbol.kind.startsWith("html-") ? 12 : 6,
    detail: symbol.kind === "function" ? symbol.tsType : symbol.odinType || symbol.tsType || symbol.kind,
    data: { patraSymbol: symbol.name },
  }));
  if (Array.isArray(result)) return [...result, ...items];
  const list = result ?? { isIncomplete: false, items: [] };
  return { ...list, items: [...(list.items ?? []), ...items] };
}

function addRpcCompletions(result, state, region, offset) {
  if (!["client", "script"].includes(region.kind)) return result;
  const before = state.text.slice(region.start, offset);
  const context = before.match(/\brpc((?:\.[A-Za-z_$][\w$]*)*)\.?$/);
  if (!context) return result;
  const parts = context[1].split(".").filter(Boolean);
  const candidates = new Map();
  for (const route of state.rpcRoutes) {
    if (!parts.every((part, index) => route.path[index] === part)) continue;
    const signature = `(${route.params.map(param => `${param.name}: ${param.type}`).join(", ")}) => Promise<${route.result}>`;
    if (parts.length < route.path.length) candidates.set(route.path[parts.length], `RPC route ${route.path.join(".")}`);
    else candidates.set(`${route.operation}()`, signature);
  }
  const items = [...candidates].map(([label, detail]) => ({ label, kind: 2, detail }));
  if (Array.isArray(result)) return [...result, ...items];
  const list = result ?? { isIncomplete: false, items: [] };
  return { ...list, items: [...(list.items ?? []), ...items] };
}

const forwardedRequests = [
  "textDocument/hover", "textDocument/completion", "textDocument/definition",
  "textDocument/references", "textDocument/implementation", "textDocument/typeDefinition",
  "textDocument/rename", "textDocument/signatureHelp", "textDocument/documentSymbol",
  "textDocument/documentHighlight", "textDocument/codeAction", "textDocument/formatting",
  "textDocument/rangeFormatting",
];

for (const method of forwardedRequests) {
  connection.onRequest(method, async params => {
    const routed = regionAt(params);
    if (!routed) return method === "textDocument/completion" ? { isIncomplete: false, items: [] } : null;

    const symbol = findSharedSymbol(routed.state, routed.region, routed.offset);
    const rpcRoute = method === "textDocument/definition" ? findRpcRouteAt(routed.state, routed.region, routed.offset) : null;
    if (rpcRoute) {
      return {
        uri: routed.state.uri,
        range: {
          start: routed.state.document.positionAt(rpcRoute.start),
          end: routed.state.document.positionAt(rpcRoute.end),
        },
      };
    }
    if (method === "textDocument/definition" && symbol) {
      return {
        uri: routed.state.uri,
        range: {
          start: routed.state.document.positionAt(symbol.start),
          end: routed.state.document.positionAt(symbol.end),
        },
      };
    }

    let result = null;
    const childPromise = children.get(serverKey(routed.region.language));
    if (childPromise) {
      try {
        const child = await childPromise;
        const forwarded = structuredClone(params);
        forwarded.textDocument.uri = routed.region.uri;
        result = await child.connection.sendRequest(method, forwarded);
        result = mapVirtualResult(result);
      } catch { }
    }
    if (method === "textDocument/completion" && visibleSymbols(routed.region, routed.state.symbols).length) {
      result = addSymbolCompletions(result, routed.state, routed.region);
    }
    if (method === "textDocument/completion") result = addRpcCompletions(result, routed.state, routed.region, routed.offset);
    return result;
  });
}

connection.onNotification("workspace/didChangeConfiguration", params => {
  for (const childPromise of children.values()) {
    childPromise.then(child => child.connection.sendNotification("workspace/didChangeConfiguration", params)).catch(() => {});
  }
});

connection.onShutdown(async () => {
  await Promise.all([...children.values()].map(async childPromise => {
    try {
      const child = await childPromise;
      await child.connection.sendRequest("shutdown");
      child.connection.sendNotification("exit");
      child.process.kill();
    } catch { }
  }));
});

connection.listen();
