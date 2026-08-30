import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';

// web-tree-sitter's recent releases are published as ESM; loading it via a
// dynamic import() (rather than a static `require`/`import` at the top of
// this CommonJS-compiled file) works regardless of whether the installed
// version is ESM, CJS, or dual-published.
type TreeSitterModule = typeof import('web-tree-sitter');

interface TSNode {
  startIndex: number;
  endIndex: number;
}

interface TSCapture {
  name: string;
  node: TSNode;
}

// Standard SemanticTokenTypes only -- every theme already knows how to
// color these without any extra `contributes.semanticTokenScopes` config.
const TOKEN_TYPES = [
  'keyword',
  'type',
  'function',
  'variable',
  'parameter',
  'property',
  'number',
  'operator',
  'comment',
  'namespace',
  'string',
] as const;

const legend = new vscode.SemanticTokensLegend([...TOKEN_TYPES], []);

// Maps a highlights.scm capture name to one of TOKEN_TYPES above.
// `punctuation.bracket` is deliberately absent -- no standard token type
// fits it, and brackets render fine in the default foreground either way.
const CAPTURE_TO_TOKEN_TYPE: Record<string, (typeof TOKEN_TYPES)[number]> = {
  keyword: 'keyword',
  type: 'type',
  'type.builtin': 'type',
  function: 'function',
  property: 'property',
  'variable.parameter': 'parameter',
  variable: 'variable',
  number: 'number',
  boolean: 'keyword', // no standard "boolean" token type exists
  'constant.builtin': 'keyword', // null
  operator: 'operator',
  comment: 'comment',
  namespace: 'namespace', // namespace/use paths, use ... as Alias
  string: 'string', // char/string literals, @autoload's own string args
};

let tsModulePromise: Promise<TreeSitterModule> | undefined;
let languagePromise: Promise<InstanceType<TreeSitterModule['Language']>> | undefined;
let highlightQuery: InstanceType<TreeSitterModule['Query']> | undefined;

async function getTreeSitterModule(): Promise<TreeSitterModule> {
  if (!tsModulePromise) {
    tsModulePromise = import('web-tree-sitter').then(async (mod) => {
      await mod.Parser.init();
      return mod;
    });
  }
  return tsModulePromise;
}

async function getLanguage(
  context: vscode.ExtensionContext
): Promise<InstanceType<TreeSitterModule['Language']>> {
  if (!languagePromise) {
    languagePromise = (async () => {
      const ts = await getTreeSitterModule();
      const wasmPath = context.asAbsolutePath('tree-sitter-postulate.wasm');
      return ts.Language.load(wasmPath);
    })();
  }
  return languagePromise;
}

async function getHighlightQuery(
  context: vscode.ExtensionContext
): Promise<InstanceType<TreeSitterModule['Query']>> {
  if (!highlightQuery) {
    const ts = await getTreeSitterModule();
    const language = await getLanguage(context);
    const queryPath = context.asAbsolutePath(path.join('queries', 'highlights.scm'));
    const querySource = fs.readFileSync(queryPath, 'utf8');
    highlightQuery = new ts.Query(language, querySource);
  }
  return highlightQuery;
}

class PostulateSemanticTokensProvider implements vscode.DocumentSemanticTokensProvider {
  constructor(private readonly context: vscode.ExtensionContext) {}

  async provideDocumentSemanticTokens(
    document: vscode.TextDocument
  ): Promise<vscode.SemanticTokens> {
    const ts = await getTreeSitterModule();
    const language = await getLanguage(this.context);
    const query = await getHighlightQuery(this.context);

    const parser = new ts.Parser();
    parser.setLanguage(language);
    const tree = parser.parse(document.getText());

    const builder = new vscode.SemanticTokensBuilder(legend);
    if (!tree) {
      return builder.build();
    }

    const captures = query.captures(tree.rootNode) as TSCapture[];
    const sorted = [...captures].sort((a, b) => a.node.startIndex - b.node.startIndex);

    for (const { name, node } of sorted) {
      const tokenType = CAPTURE_TO_TOKEN_TYPE[name];
      if (!tokenType) {
        continue;
      }
      const range = new vscode.Range(
        document.positionAt(node.startIndex),
        document.positionAt(node.endIndex)
      );
      // The range overload splits multi-line ranges (e.g. block comments)
      // into per-line tokens internally, per the semantic tokens protocol.
      builder.push(range, tokenType);
    }

    return builder.build();
  }
}

export function activate(context: vscode.ExtensionContext): void {
  const provider = new PostulateSemanticTokensProvider(context);
  context.subscriptions.push(
    vscode.languages.registerDocumentSemanticTokensProvider(
      { language: 'postulate' },
      provider,
      legend
    )
  );
}

export function deactivate(): void {
  // nothing to tear down
}
