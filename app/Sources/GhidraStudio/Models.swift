import Foundation

struct ProgramInfo: Codable, Equatable {
    let name: String
    let path: String
    let format: String
    let language: String
    let processor: String
    let compiler: String
    let endian: String
    let pointerSize: Int
    let imageBase: String
    let minAddress: String?
    let maxAddress: String?
    let md5: String?
    let sha256: String?
    let functionCount: Int
    let created: String
    let entry: String?
    let analyzing: Bool?
    var session: String? = nil
    var domainPath: String? = nil
    var changed: Bool? = nil
    var canUndo: Bool? = nil
    var canRedo: Bool? = nil
    var undoName: String? = nil
    var redoName: String? = nil
    var readOnly: Bool? = nil
}

struct FunctionItem: Codable, Identifiable, Hashable {
    let address: String
    let name: String
    let size: Int
    let thunk: Bool
    let signature: String
    var id: String { address }
}

struct ImportItem: Codable, Identifiable, Hashable {
    let name: String
    let library: String
    let address: String?
    var id: String { "\(library)::\(name)" }
}

struct ExportItem: Codable, Identifiable, Hashable {
    let address: String
    let name: String
    let isFunction: Bool
    var id: String { "\(address)|\(name)" }
}

struct StringItem: Codable, Identifiable, Hashable {
    let address: String
    let value: String
    let length: Int
    let type: String
    let xrefs: Int
    var id: String { address }
}

struct SegmentItem: Codable, Identifiable, Hashable {
    let name: String
    let start: String
    let end: String
    let size: Int64
    let perms: String
    let initialized: Bool
    let comment: String?
    var volatile: Bool? = nil
    var artificial: Bool? = nil
    var overlay: Bool? = nil
    var id: String { "\(name)@\(start)" }
}

struct SearchHit: Codable, Identifiable, Hashable {
    let address: String
    let name: String
    let kind: String
    var id: String { "\(address)|\(name)" }
}

struct DecompToken: Codable {
    let t: String
    let s: Int
    let k: String
    let target: String?
    var v: String? = nil
    /// Token id (for slicing), field owner type + offset, call-site address.
    var i: Int? = nil
    var ft: String? = nil
    var fo: Int? = nil
    var call: String? = nil
    /// The variable instance can be split out as a new variable.
    var sp: Bool? = nil
    /// The token is a field of a union (its choice can be forced).
    var un: Bool? = nil
}

struct DecompLine: Codable {
    let indent: Int
    let tokens: [DecompToken]
    let addr: String?
    /// Every address the tokens of the line come from (when more than one).
    var addrs: [String]? = nil
}

struct Decompilation: Codable {
    let function: String
    let entry: String
    let signature: String
    let lines: [DecompLine]
}

struct Operand: Codable {
    let text: String
    let target: String?
}

struct ListingRow: Codable {
    let address: String
    let bytes: String
    let label: String?
    let mnemonic: String
    let kind: String
    let operands: [Operand]
    let flow: String?
    let eol: String?
    let pre: String?
    let plate: String?
    let post: String?
    let xrefs: Int
    var fnStart: String? = nil
    var blockStart: String? = nil
    var repeatable: String? = nil
    var bookmark: String? = nil
    /// Jump targets of a branch instruction and whether it is conditional.
    var jumps: [String]? = nil
    var conditional: Bool? = nil
    /// Optional fields, sent only when the listing options ask for them.
    var fileOffset: String? = nil
    var functionOffset: String? = nil
    var pcode: [String]? = nil
    var xrefList: [String]? = nil
    var source: String? = nil
    /// Number of components when the data is a structure or an array (it can be opened in the listing).
    var components: Int? = nil
    /// Set on the first line of a folded function: how many bytes of it are hidden.
    var folded: Int? = nil
    /// References that reach the function through its thunks.
    var thunkXrefs: Int? = nil
}

struct ListingSpan: Codable {
    let rows: [ListingRow]
    let atEdge: Bool
}

struct Listing: Codable {
    let function: String?
    let entry: String?
    let signature: String?
    let rows: [ListingRow]
}

struct HexDump: Codable {
    let start: String
    let bytes: [Int]
    let block: String?
}

struct XRef: Codable, Identifiable, Hashable {
    let from: String
    let type: String
    let function: String?
    /// The thunk the reference goes through, when thunk references are shown.
    var via: String? = nil
    var id: String { "\(from)|\(type)|\(via ?? "")" }
}

struct FnRef: Codable, Identifiable, Hashable {
    let name: String
    let address: String
    let external: Bool
    var id: String { address }
}

struct Param: Codable, Hashable {
    let name: String
    let type: String
    let storage: String
}

struct FunctionDetails: Codable {
    let name: String
    let entry: String
    let signature: String
    let callingConvention: String?
    let returnType: String
    let size: Int
    let thunk: Bool
    let thunkTarget: String?
    let comment: String?
    let parameters: [Param]
    let localCount: Int
    let callers: [FnRef]
    let callees: [FnRef]
    let xrefs: [XRef]
}

struct Resolved: Codable {
    let address: String
    let function: String?
}

/// Parses the numeric part of a Ghidra address string ("100000460", "ram:1000", ...).
func addressValue(_ s: String) -> UInt64? {
    let part = s.split(separator: ":").last.map(String.init) ?? s
    return UInt64(part, radix: 16)
}

// MARK: - Projects

struct ProjectClip: Equatable {
    let path: String
    let folder: Bool
}

struct ProjectInfo: Codable, Equatable {
    let open: Bool
    var name: String? = nil
    var directory: String? = nil
    var gpr: String? = nil
    var isDefault: Bool? = nil
    var tree: ProjectFolder? = nil
    var server: ServerStatus? = nil
}

/// Ghidra Server binding of a shared project.
struct ServerStatus: Codable, Equatable {
    let shared: Bool
    var host: String? = nil
    var port: Int? = nil
    var repository: String? = nil
    var connected: Bool? = nil
    var user: String? = nil
    var access: String? = nil
}

struct ProjectFolder: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let folders: [ProjectFolder]
    let files: [ProjectFile]
    var id: String { "d:" + path }

    var allFolders: [ProjectFolder] { [self] + folders.flatMap(\.allFolders) }
}

struct ProjectFile: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let contentType: String
    let format: String?
    let processor: String?
    let language: String?
    let modified: Int64
    let open: Bool
    let program: Bool
    var versioned: Bool? = nil
    var checkedOut: Bool? = nil
    var version: Int? = nil
    var id: String { "f:" + path }
}

struct LoadSpecItem: Codable, Identifiable, Hashable {
    let loader: String
    let tier: String
    let language: String?
    let compiler: String?
    let preferred: Bool
    let imageBase: String
    var id: String { "\(loader)|\(language ?? "")|\(compiler ?? "")" }
    var title: String {
        guard let language else { return loader }
        return "\(loader) · \(language) · \(compiler ?? "default")"
    }
}

struct LanguageItem: Codable, Identifiable, Hashable {
    let id: String
    let processor: String
    let endian: String
    let size: Int
    let variant: String
    let description: String
    let compilers: [String]
}

struct UndoState: Codable, Equatable {
    let changed: Bool
    let canUndo: Bool
    let canRedo: Bool
    let undoName: String?
    let redoName: String?
}

struct BookmarkItem: Codable, Identifiable, Hashable {
    let address: String
    let type: String
    let category: String
    let comment: String
    var id: String { "\(address)|\(type)|\(category)" }

    static let breakpointEnabled = "BreakpointEnabled"
    static let breakpointDisabled = "BreakpointDisabled"
    var isBreakpoint: Bool { type == Self.breakpointEnabled || type == Self.breakpointDisabled }
}

// MARK: - Types

struct DataTypeItem: Codable, Identifiable, Hashable {
    let path: String
    let name: String
    let category: String
    let kind: String
    let size: Int
    let builtin: Bool
    var id: String { path }
}

struct TypeField: Codable, Identifiable, Hashable {
    var ordinal: Int? = nil
    var offset: Int? = nil
    var length: Int? = nil
    var type: String? = nil
    var name: String? = nil
    var comment: String? = nil
    var value: Int64? = nil
    var id: String { "\(ordinal ?? -1)|\(name ?? "")|\(value ?? 0)" }
}

struct DataTypeDetail: Codable {
    let path: String
    let name: String
    let kind: String
    let size: Int
    let description: String?
    let editable: Bool
    let fields: [TypeField]
    var base: String? = nil
    var c: String? = nil
    var packed: Bool? = nil
    var packValue: Int? = nil
    var alignment: Int? = nil
    /// Set while the structure editor has a working copy of the type: its id and the state of its history.
    var editor: String? = nil
    var canUndo: Bool? = nil
    var canRedo: Bool? = nil
    var dirty: Bool? = nil
}

struct PathResult: Codable { let path: String }

// MARK: - Graphs, search, scripts, export

struct GraphBlock: Codable, Identifiable, Hashable {
    let id: Int
    let start: String
    let end: String
    let label: String?
    let lines: [String]
    let entry: Bool
    /// The address of each line (the last line may be a "… more" note without one).
    var addresses: [String]? = nil
    /// Set on the node that stands for a collapsed group of blocks.
    var group: UUID? = nil
}

struct GraphEdge: Codable, Hashable {
    let from: Int
    let to: Int
    let kind: String
}

struct FunctionGraphData: Codable {
    let function: String
    let entry: String
    let blocks: [GraphBlock]
    let edges: [GraphEdge]
    let truncated: Bool
}

struct CallItem: Codable, Identifiable, Hashable {
    let name: String
    let address: String
    let external: Bool
    let hasChildren: Bool
    var id: String { address }
}

struct SearchResult: Codable, Identifiable, Hashable {
    let address: String
    let kind: String
    let text: String
    let function: String?
    var id: String { "\(address)|\(kind)|\(text.prefix(40))" }
}

struct AnalyzerOption: Codable, Identifiable, Hashable {
    let name: String
    var enabled: Bool
    let description: String?
    var id: String { name }
}

struct ExporterItem: Codable, Identifiable, Hashable {
    let name: String
    let `extension`: String
    var id: String { name }
}

struct ScriptItem: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let category: String
    let description: String
    let user: Bool
    var language: String? = nil
    var id: String { path }
    var isPython: Bool { language == "python" }
}

struct ScriptResult: Codable {
    let output: String
    let error: String?
    let millis: Int
}

struct SavedScript: Codable {
    let path: String
    let name: String
}

struct ExportResult: Codable {
    let path: String
    let size: Int64
}

struct AssembleResult: Codable {
    let bytes: String
}

struct ActiveResult: Codable {
    let active: String?
}

// MARK: - Emulator

struct EmuRegister: Codable, Identifiable, Hashable {
    let name: String
    let value: String
    let bits: Int
    var id: String { name }
}

struct EmuWrite: Codable, Identifiable, Hashable {
    let address: String
    let length: Int64
    let bytes: String
    var id: String { address }
}

struct EmuState: Codable {
    let running: Bool
    let status: String
    let steps: Int64
    let breakpoints: [String]
    var skipExternal: Bool? = nil
    var log: [String]? = nil
    var pc: String? = nil
    var function: String? = nil
    var instruction: String? = nil
    var registers: [EmuRegister]? = nil
    var writes: [EmuWrite]? = nil
    var pcode: EmuPcode? = nil
    var watches: [EmuWatch]? = nil
    var threads: [EmuThread]? = nil
}

/// The p-code of the instruction at the program counter, and how far its execution has got.
struct EmuPcode: Codable {
    let ops: [String]
    let index: Int
    let active: Bool
    let uniques: [EmuWatch.Value]
}

struct EmuWatch: Codable, Hashable {
    struct Value: Codable, Hashable {
        let name: String
        let value: String
    }

    let expression: String
    let value: String
}

struct EmuThread: Codable, Identifiable, Hashable {
    let index: Int
    let pc: String
    let current: Bool
    var id: Int { index }
}

// MARK: - Comparison

struct DiffRow: Codable, Identifiable, Hashable {
    let address: String
    let end: String
    let kind: String
    let length: Int64
    let function: String?
    var id: String { "\(address)|\(kind)" }
}

struct DiffResult: Codable {
    let differences: [DiffRow]
    let onlyInThis: [String]
    let onlyInOther: [String]
    let warnings: String?
    let truncated: Bool
}

struct FunctionMatch: Codable, Identifiable, Hashable {
    let address: String
    let name: String
    let otherAddress: String
    let otherName: String
    let sameName: Bool
    let otherNamed: Bool
    let size: Int
    var id: String { "\(address)|\(otherAddress)" }
}

struct AppliedResult: Codable { let applied: Int }

// MARK: - Symbols, references, equates, archives

struct NamespaceNode: Codable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let kind: String
    let address: String?
    let container: Bool
    let external: Bool
}

struct RefFrom: Codable, Identifiable, Hashable {
    let to: String
    let type: String
    let operand: Int
    let source: String
    let primary: Bool
    let function: String?
    var id: String { "\(to)|\(type)|\(operand)" }
}

struct TypeArchive: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
}

// MARK: - Node graphs (call graph, references)

struct GNode: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let detail: String
    let kind: String
    var level: Int? = nil
    let address: String?
    /// Last address of what the node stands for (blocks, data).
    var end: String? = nil
}

struct GEdge: Codable, Hashable {
    let from: String
    let to: String
    let kind: String
}

struct NodeGraphData: Codable {
    let nodes: [GNode]
    let edges: [GEdge]
    let truncated: Bool

    /// Graphviz DOT export.
    var dot: String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var out = "digraph G {\n  node [shape=box, style=rounded, fontname=\"Menlo\"];\n"
        for n in nodes { out += "  \(q(n.id)) [label=\(q(n.label + "\\n" + n.detail))];\n" }
        for e in edges { out += "  \(q(e.from)) -> \(q(e.to));\n" }
        return out + "}\n"
    }
}

// MARK: - Import, options, function editor, tables

struct FSEntry: Codable, Identifiable, Hashable {
    let name: String
    let fsrl: String
    let directory: Bool
    let size: Int64
    var id: String { fsrl }
}

struct FSListing: Codable {
    let container: Bool
    let entries: [FSEntry]
    let type: String?
}

struct LoaderOption: Codable, Identifiable, Hashable {
    let name: String
    let arg: String
    let type: String
    var value: String
    let group: String?
    var id: String { arg }
}

struct TypedOption: Codable, Identifiable, Hashable {
    var key: String? = nil
    var name: String? = nil
    let label: String
    let type: String
    var value: String
    var choices: [String]? = nil
    var description: String? = nil
    var id: String { key ?? name ?? label }
}

struct FunctionVariable: Codable, Identifiable, Hashable {
    let name: String
    let type: String
    let storage: String
    let size: Int
    let parameter: Bool
    let stackOffset: Int?
    let comment: String?
    var id: String { name + storage }
}

struct FunctionProperties: Codable {
    let name: String
    let entry: String
    let signature: String
    let callingConvention: String?
    let conventions: [String]
    let noReturn: Bool
    let inline: Bool
    let varArgs: Bool
    let customStorage: Bool
    let thunk: Bool
    let stackSize: Int
    let localSize: Int
    let paramSize: Int
    let variables: [FunctionVariable]
    let tags: [String]
    let allTags: [String]
    let callFixup: String?
}

struct ContextRegister: Codable, Identifiable, Hashable {
    let name: String
    let bits: Int
    let value: String?
    let context: Bool
    var id: String { name }
}

struct SymbolRow: Codable, Identifiable, Hashable {
    let name: String
    let address: String?
    let kind: String
    let namespace: String
    let source: String
    let references: Int
    let primary: Bool
    var id: String { "\(address ?? "ext")|\(name)|\(kind)|\(namespace)" }
}

struct RelocationRow: Codable, Identifiable, Hashable {
    let address: String
    let type: String
    let status: String
    let symbol: String?
    let values: String
    let bytes: String
    var id: String { address + type }
}

struct FoundStringRow: Codable, Identifiable, Hashable {
    let address: String
    let length: Int
    let value: String
    let defined: Bool
    var id: String { address }
}

struct EquateRow: Codable, Identifiable, Hashable {
    let name: String
    let value: Int64
    let references: Int
    var id: String { name }
}

struct FunctionText: Codable {
    let name: String
    let entry: String
    let program: String
    let lines: [String]
}

struct ImportedInfo: Codable {
    let path: String
    let imported: [String]?
}

struct PatternResult: Codable {
    let pattern: String
    let instructions: Int
    let results: [SearchResult]
}

struct TreeGroup: Codable, Identifiable, Hashable {
    let name: String
    let module: Bool
    let start: String?
    let end: String?
    let children: [TreeGroup]
    var id: String { "\(name)|\(start ?? "")" }
}

// MARK: - Long tasks

struct TaskStatus: Equatable {
    var message: String
    var progress: Double?
}

// MARK: - Python

struct PyResult: Codable {
    let output: String
    let millis: Int
}

// MARK: - BSim

struct BsimDatabase: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    var size: Int64? = nil
    var local: Bool? = nil
    var id: String { path }
}

struct BsimDatabases: Codable {
    let databases: [BsimDatabase]
    let templates: [String]
    let directory: String
}

struct BsimExecutable: Codable, Identifiable, Hashable {
    let name: String
    let md5: String
    let architecture: String?
    let compiler: String?
    let date: Int64?
    var id: String { md5 }
}

struct BsimInfo: Codable {
    let name: String?
    let owner: String?
    let description: String?
    let version: String
    let readOnly: Bool
    let callGraph: Bool
    let url: String?
    let executables: [BsimExecutable]
    let count: Int
}

struct BsimAddResult: Codable {
    let executables: Int
    let functions: Int
    let total: Int?
}

struct BsimRow: Codable, Identifiable, Hashable {
    let address: String
    let name: String
    let matchName: String
    let matchAddress: String
    let executable: String
    let md5: String
    let architecture: String?
    let similarity: Double
    let confidence: Double
    let defaultName: Bool
    var id: String { "\(address)|\(md5)|\(matchAddress)" }
}

struct BsimQueryResult: Codable {
    let queried: Int
    let matched: Int
    let rows: [BsimRow]
}

// MARK: - Version Tracking

struct VTSessionFile: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let modified: Int64
    let open: Bool
    var id: String { path }
}

struct VTMatchSetInfo: Codable, Identifiable, Hashable {
    let id: Int
    let correlator: String
    let matches: Int
}

struct VTState: Codable, Equatable {
    let open: Bool
    var name: String? = nil
    var path: String? = nil
    var source: String? = nil
    var sourcePath: String? = nil
    var destination: String? = nil
    var destinationPath: String? = nil
    var matchSets: [VTMatchSetInfo]? = nil
    var matches: Int? = nil
    var associations: Int? = nil
    var accepted: Int? = nil
    var changed: Bool? = nil
}

struct VTCorrelator: Codable, Identifiable, Hashable {
    let name: String
    let description: String?
    let priority: Int
    var options: [TypedOption]
    var id: String { name }
}

struct VTCorrelators: Codable {
    let correlators: [VTCorrelator]
    let auto: [TypedOption]
}

struct VTMatch: Codable, Identifiable, Hashable {
    let key: String
    let set: Int
    let correlator: String
    let type: String
    let status: String
    let markup: String?
    let score: Double
    let confidence: Double
    let votes: Int
    let sourceAddress: String
    let sourceName: String
    let sourceLength: Int
    let destinationAddress: String
    let destinationName: String
    let destinationLength: Int
    let tag: String?
    var id: String { key }
}

struct VTMarkupItem: Codable, Identifiable, Hashable {
    let index: Int
    let type: String
    let status: String
    let statusText: String?
    let detail: String?
    let sourceAddress: String?
    let sourceValue: String?
    let destinationAddress: String?
    let destinationValue: String?
    let originalValue: String?
    let canApply: Bool
    let canUnapply: Bool
    var id: Int { index }
}

struct VTRunResult: Codable {
    struct Entry: Codable, Hashable {
        let correlator: String
        let matches: Int
    }
    let results: [Entry]
    let state: VTState
}

struct VTAutoResult: Codable {
    let message: String?
    let state: VTState
}

struct VTMarkupApplied: Codable {
    let markup: [VTMarkupItem]
}

struct VTManualResult: Codable {
    let key: String?
}

// MARK: - Ghidra Server & version control

struct ServerConnection: Codable {
    let connected: Bool
    let host: String
    let port: Int
    let user: String?
    let readOnly: Bool
    let repositories: [String]
    let users: [String]
    let systemUser: String?
}

struct RepositoryList: Codable {
    let repositories: [String]
}

struct RepositoryUser: Codable, Identifiable, Hashable {
    let name: String
    let access: String
    var id: String { name }
}

struct VCFile: Codable, Identifiable, Hashable {
    let path: String
    let name: String
    let contentType: String
    let state: String
    let versioned: Bool
    let checkedOut: Bool
    let exclusive: Bool
    let version: Int?
    let latest: Int?
    let canCheckout: Bool
    let canCheckin: Bool
    let canMerge: Bool
    let canAdd: Bool
    let checkedOutBy: String?
    let open: Bool
    var id: String { path }
}

struct VCFiles: Codable {
    let files: [VCFile]
    let server: ServerStatus
}

struct VCVersion: Codable, Identifiable, Hashable {
    let version: Int
    let user: String?
    let comment: String?
    let date: Int64
    var id: Int { version }
}

struct ExtractedVersion: Codable {
    let path: String
    let name: String
}

// MARK: - Extensions

struct ExtensionItem: Codable, Identifiable, Hashable {
    let name: String
    let description: String?
    let author: String?
    let created: String?
    let version: String?
    let installed: Bool
    let pendingUninstall: Bool
    let bundled: Bool
    let compatible: Bool
    let installPath: String?
    let archivePath: String?
    var id: String { name }
}

struct ExtensionList: Codable {
    let extensions: [ExtensionItem]
    let directory: String
    let ghidraVersion: String
}

// MARK: - Function ID

struct FidLibrary: Codable, Hashable {
    let family: String
    let version: String
    let variant: String
    let language: String
}

struct FidFileItem: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let installed: Bool
    let active: Bool
    let libraries: [FidLibrary]
    var id: String { path }
}

struct FidFileList: Codable {
    let files: [FidFileItem]
    let directory: String
}

struct FidPopulateResult: Codable {
    let added: Int
    let excluded: Int
    let attempted: Int
}

// MARK: - Graph groups

/// Blocks of a function graph collapsed into one node.
struct GraphGroup: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Start addresses of the member blocks.
    var members: [String]
}

// MARK: - Program tools (namespaces, externals, checksums, entropy, source files, stack frame)

struct NamespaceItem: Codable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let kind: String
}

struct ExternalLocationItem: Codable, Identifiable, Hashable {
    let id: Int64
    let label: String?
    let original: String?
    let address: String?
    let function: Bool
}

struct ExternalLibrary: Codable, Identifiable, Hashable {
    let library: String
    let path: String?
    let locations: [ExternalLocationItem]
    var id: String { library }
}

struct ChecksumRow: Codable, Identifiable, Hashable {
    let name: String
    let value: String
    var id: String { name }
}

struct ChecksumResult: Codable {
    let bytes: Int
    let checksums: [ChecksumRow]
    let range: String?
}

struct EntropyBlock: Codable, Identifiable, Hashable {
    let block: String
    let start: String
    let size: Int64
    let chunk: Int
    let average: Double
    let values: [Double]
    var id: String { block + start }
}

struct SourceFileItem: Codable, Identifiable, Hashable {
    let path: String
    let name: String
    let entries: Int
    let address: String?
    var id: String { path }
}

struct SourceLine: Codable, Identifiable, Hashable {
    let line: Int
    let address: String
    let length: Int64
    var id: String { "\(line)|\(address)" }
}

struct StackVariable: Codable, Identifiable, Hashable {
    let offset: Int
    let length: Int
    let name: String
    let type: String
    let parameter: Bool
    let comment: String?
    var id: Int { offset }
}

struct StackFrameInfo: Codable {
    let function: String
    let entry: String
    let frameSize: Int
    let localSize: Int
    let parameterSize: Int
    let parameterOffset: Int
    let returnAddressOffset: Int
    let growsNegative: Bool
    let variables: [StackVariable]
}

struct UnionChoice: Codable, Identifiable, Hashable {
    let index: Int
    let name: String
    let type: String
    var id: Int { index }
}

struct UnionChoices: Codable {
    let union: String
    let current: String
    let choices: [UnionChoice]
}

struct ValueSearchResult: Codable {
    let pattern: String
    let results: [SearchResult]
}

struct DiffApplyResult: Codable {
    let applied: Int64
    let error: String?
    let info: String?
}

struct DisassembleResult: Codable {
    let instructions: Int64
}

struct PdbInfo: Codable {
    let available: Bool
    var name: String? = nil
    var id: String? = nil
    var description: String? = nil
}

struct PdbDownload: Codable {
    let path: String
}

struct VTImpliedMatch: Codable, Identifiable, Hashable {
    let sourceAddress: String
    let sourceName: String
    let destinationAddress: String
    let destinationName: String
    let type: String
    let status: String?
    var id: String { sourceAddress + ">" + destinationAddress }
}

struct BsimCompareRow: Codable, Identifiable, Hashable {
    let name: String
    let md5: String
    let architecture: String?
    let library: Double
    let total: Double
    var id: String { md5 }
}

struct VCCheckout: Codable, Identifiable, Hashable {
    let id: Int64
    let user: String
    let version: Int
    let date: Int64
    let project: String?
    let exclusive: Bool
}

struct FidFunction: Codable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let library: String
    let size: Int
    let hash: String
    let excluded: Bool
    let forced: Bool
}

struct CreatedNamespace: Codable {
    let id: Int64
    let name: String
}

struct ExportedTypes: Codable {
    let path: String
    let added: Int
    let total: Int
}

struct CreatedType: Codable {
    let path: String
    let name: String
}

// MARK: - Overview bar, program selection, extra listing windows

struct OverviewRange: Codable, Hashable {
    let start: String
    let end: String
    let offset: Int64
    let size: Int64
    let name: String
}

struct OverviewChange: Codable, Hashable {
    let start: String
    let end: String
}

/// The whole program in slices, for the overview bar next to the listing.
struct ProgramOverview: Codable, Equatable {
    let total: Int64
    let ranges: [OverviewRange]
    /// 0 function, 1 instruction outside a function, 2 data, 3 undefined, 4 uninitialized, 5 external.
    let kinds: [Int]
    let starts: [String]
    let changes: [OverviewChange]

    /// Position of an address in the bar, 0…1.
    func fraction(_ address: String) -> Double? {
        guard total > 0, let v = addressValue(address) else { return nil }
        let space = address.contains(":") ? String(address[..<address.lastIndex(of: ":")!]) : ""
        for r in ranges {
            let rs = r.start.contains(":") ? String(r.start[..<r.start.lastIndex(of: ":")!]) : ""
            guard rs == space, let lo = addressValue(r.start), let hi = addressValue(r.end), v >= lo, v <= hi else { continue }
            return (Double(r.offset) + Double(v - lo)) / Double(total)
        }
        return nil
    }
}

struct SelectionResult: Codable {
    let ranges: [[String]]
    let rangeCount: Int
    let addresses: Int64
    let truncated: Bool
    let first: String?
}

/// A set of address ranges selected in the program (Ghidra's selection), independent of the text selection.
struct ProgramSelection: Equatable {
    let id = UUID()
    let ranges: [[String]]
    let rangeCount: Int
    let addresses: Int64
    let truncated: Bool
    /// Numeric bounds, sorted, for fast "is this line selected".
    let bounds: [ClosedRange<UInt64>]

    init(_ r: SelectionResult) {
        ranges = r.ranges
        rangeCount = r.rangeCount
        addresses = r.addresses
        truncated = r.truncated
        bounds = r.ranges.compactMap { pair -> ClosedRange<UInt64>? in
            guard pair.count == 2, let lo = addressValue(pair[0]), let hi = addressValue(pair[1]), lo <= hi else { return nil }
            return lo...hi
        }.sorted { $0.lowerBound < $1.lowerBound }
    }

    func contains(_ v: UInt64) -> Bool {
        var lo = 0, hi = bounds.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if v < bounds[mid].lowerBound { hi = mid - 1 } else if v > bounds[mid].upperBound { lo = mid + 1 } else { return true }
        }
        return false
    }

    static func == (a: ProgramSelection, b: ProgramSelection) -> Bool { a.id == b.id }
}

/// An extra, independent code window (Ghidra's listing / decompiler snapshot).
struct SnapshotSpec: Codable, Hashable {
    var id = UUID()
    let session: String
    let address: String
    /// "decompiler" or "listing".
    let mode: String
}
