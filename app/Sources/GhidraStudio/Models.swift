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
}

struct DecompLine: Codable {
    let indent: Int
    let tokens: [DecompToken]
    let addr: String?
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
    var id: String { "\(from)|\(type)" }
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

struct ProjectInfo: Codable, Equatable {
    let open: Bool
    var name: String? = nil
    var directory: String? = nil
    var gpr: String? = nil
    var isDefault: Bool? = nil
    var tree: ProjectFolder? = nil
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
    var id: String { path }
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
    var pc: String? = nil
    var function: String? = nil
    var instruction: String? = nil
    var registers: [EmuRegister]? = nil
    var writes: [EmuWrite]? = nil
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
