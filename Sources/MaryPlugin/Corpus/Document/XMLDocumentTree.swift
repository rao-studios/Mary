//
//  XMLDocumentTree.swift
//  MaryPlugin
//
//  A READ-ONLY XML TREE, because Foundation gives an event stream.
//
//  `XMLParser` is SAX: it calls back as it goes and holds nothing. Reading a
//  manifest means asking questions about STRUCTURE — what is under this
//  element, what does its title child say — and answering those from a stream
//  means every caller keeping its own stack. This builds the tree once so the
//  reader can ask.
//
//  `XMLDocument` would do this in one line and is unavailable outside macOS's
//  Foundation on some platforms; the parse below is thirty lines and keeps
//  the corpus lane portable.
//
//  BOUNDED, because a manifest is a file on disk that Mary did not write. A
//  project with a hundred thousand items, or a maliciously nested one, must
//  not become an unbounded allocation inside a turn.
//

import Foundation

final class XMLDocumentTree: NSObject, XMLParserDelegate {

    final class Node {
        let name: String
        let attributes: [String: String]
        private(set) var childNodes: [Node] = []
        /// Character data directly inside this element, trimmed.
        private(set) var text: String?

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        func append(_ child: Node) { childNodes.append(child) }

        func append(text fragment: String) {
            text = (text ?? "") + fragment
        }

        func finalizeText() {
            text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            if text?.isEmpty == true { text = nil }
        }

        func children(named name: String) -> [Node] {
            childNodes.filter { $0.name == name }
        }

        func firstChild(named name: String) -> Node? {
            childNodes.first { $0.name == name }
        }
    }

    /// Deep enough for any real outline; a manifest nested past this is not a
    /// manuscript.
    static let maximumDepth = 64
    static let maximumNodes = 200_000

    private var root: Node?
    private var stack: [Node] = []
    private var nodeCount = 0
    private var overflowed = false

    init(contentsOf url: URL) throws {
        super.init()
        let data = try Data(contentsOf: url)
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), !overflowed else {
            throw parser.parserError
                ?? NSError(
                    domain: "XMLDocumentTree", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        overflowed ? "the outline is too large to read" : "malformed"])
        }
    }

    /// The first element anywhere with this name, breadth-first — a
    /// manifest's outline root is a child of the document root, not the
    /// document root itself.
    func firstDescendant(named name: String) -> Node? {
        guard let root else { return nil }
        if root.name == name { return root }
        var queue = root.childNodes
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if node.name == name { return node }
            queue.append(contentsOf: node.childNodes)
        }
        return nil
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        nodeCount += 1
        guard nodeCount <= Self.maximumNodes, stack.count < Self.maximumDepth else {
            overflowed = true
            parser.abortParsing()
            return
        }
        let node = Node(name: elementName, attributes: attributes)
        stack.last?.append(node)
        if root == nil { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.append(text: string)
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        stack.popLast()?.finalizeText()
    }
}
