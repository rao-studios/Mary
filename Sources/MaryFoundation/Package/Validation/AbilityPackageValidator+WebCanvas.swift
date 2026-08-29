//
//  AbilityPackageValidator+WebCanvas.swift
//  MaryFoundation
//
//  ADMITTING A DECLARED WEB CANVAS.
//
//  `webCanvas` shipped without a validator. Nothing checked it beyond
//  `rejectUnknownKeys` at decode, which catches a misspelled key and nothing
//  else — so `WebCanvasSchema`'s own documentation was, until this file,
//  describing rules that did not exist: "http/https only, admitted at
//  validation" was admitted nowhere, and "a package proposes and the validator
//  bounds it" bounded nothing.
//
//  IT MATTERS MORE THAN A MISSING VALIDATOR USUALLY WOULD, because two of
//  these fields now reach the MODEL. `WebCanvasContract` shapes `contentNoun`
//  and `requiredContentMarker` into Mary-authored sentences in the tool schema
//  and the prompt, on the standing rule that a VALIDATED TOKEN may be shaped
//  into Mary's words while authored prose may not. That rule is only worth
//  anything if the token is genuinely a token — so the constraints here are
//  what makes the derivation upstream legitimate, and loosening one of them
//  loosens the prompt.
//
//  WHAT A TOKEN MAY BE, therefore: a short word or two, letters and spaces and
//  the punctuation that appears inside real identifiers. What it may not be is
//  a sentence, a newline, a quotation mark, or long enough to hide one.
//

import Foundation

extension AbilityPackageValidator {

    /// Only these may be spoken to a browser.
    static let webCanvasSchemes: Set<String> = ["http", "https"]

    /// A paste larger than an editor can hold is a hang rather than an error,
    /// so the ceiling is a real bound and not a formality.
    static let maximumCanvasContentBytes = 262_144

    /// Long enough for "shader code" or "mainImage"; far too short for a
    /// sentence with an instruction in it.
    static let maximumCanvasTokenBytes = 64

    /// Bounded so a declaration cannot turn a per-poll banner sweep into a
    /// full-page search, and cannot pad the derived sentence with fifty nouns.
    static let maximumCanvasPhrases = 32
    static let maximumCanvasPhraseBytes = 128

    static func validateWebCanvas(
        _ package: MaryAbilityPackage,
        _ sink: PackageIssueSink
    ) {
        guard let canvas = package.webCanvas else { return }
        validateWebCanvas(canvas, sink)
    }

    /// Over the block alone — every rule here is a rule about the declaration
    /// and none of them needs the package around it, so the tests do not have
    /// to build one.
    static func validateWebCanvas(
        _ canvas: WebCanvasSchema,
        _ sink: PackageIssueSink
    ) {
        let path = "webCanvas"

        // THE ADDRESS. `javascript:` and `data:` are refused here rather than
        // at the browser, which is the no-JavaScript doctrine made structural:
        // the lane cannot be asked to go somewhere it would have to refuse.
        let address = canvas.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: address),
           let scheme = url.scheme?.lowercased(),
           webCanvasSchemes.contains(scheme),
           url.host?.isEmpty == false,
           address == canvas.address {
            // admitted
        } else {
            sink.error(
                "invalid-canvas-address",
                "\(path).address",
                "A web canvas address must be a trimmed http or https URL with a host.")
        }

        // THE NOUN reaches the model inside a sentence Mary wrote. See the
        // header: this constraint is what makes that derivation legitimate.
        checkCanvasToken(canvas.contentNoun, "\(path).contentNoun", "noun", sink)

        if let marker = canvas.requiredContentMarker {
            checkCanvasToken(marker, "\(path).requiredContentMarker", "marker", sink)
        }

        if canvas.contentLimitBytes <= 0
            || canvas.contentLimitBytes > maximumCanvasContentBytes {
            sink.error(
                "invalid-canvas-limit",
                "\(path).contentLimitBytes",
                "A content limit must be between 1 and \(maximumCanvasContentBytes) bytes.")
        }

        // THE STATUS MARKER is read as evidence — its ABSENCE means the tool
        // never ran — so an empty one would make every run report that it did
        // not happen. Absent is fine; present and blank is not.
        if let status = canvas.statusMarker {
            checkCanvasPhrase(status, "\(path).statusMarker", sink)
        }

        checkCanvasPhrases(canvas.consentLabels, "\(path).consentLabels", sink)
        checkCanvasPhrases(canvas.diagnosticPhrases, "\(path).diagnosticPhrases", sink)
        checkCanvasPhrases(canvas.editorHints, "\(path).editorHints", sink)
    }

    /// A token: present, short, single-line, and not carrying quotation marks
    /// that could close the one `WebCanvasContract` wraps it in.
    static func checkCanvasToken(
        _ value: String, _ path: String, _ noun: String, _ sink: PackageIssueSink
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              value.utf8.count <= maximumCanvasTokenBytes,
              !value.contains(where: { $0.isNewline || $0 == "\"" })
        else {
            sink.error(
                "invalid-canvas-\(noun)",
                path,
                "A canvas \(noun) must be a trimmed single-line word of at most \(maximumCanvasTokenBytes) UTF-8 bytes, without quotation marks.")
            return
        }
    }

    /// A phrase is matched against a page, never spoken, so it may be longer
    /// and freer than a token — but it is still one line, and still present.
    static func checkCanvasPhrase(
        _ value: String, _ path: String, _ sink: PackageIssueSink
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty
            || value.utf8.count > maximumCanvasPhraseBytes
            || value.contains(where: \.isNewline) {
            sink.error(
                "invalid-canvas-phrase",
                path,
                "A canvas phrase must be non-empty, single-line, and at most \(maximumCanvasPhraseBytes) UTF-8 bytes.")
        }
    }

    static func checkCanvasPhrases(
        _ values: [String], _ path: String, _ sink: PackageIssueSink
    ) {
        if values.count > maximumCanvasPhrases {
            sink.error(
                "too-many-canvas-phrases",
                path,
                "A canvas phrase list may contain at most \(maximumCanvasPhrases) entries.")
        }
        let inspected = Array(values.prefix(maximumCanvasPhrases))
        for (index, value) in inspected.enumerated() {
            checkCanvasPhrase(value, "\(path)[\(index)]", sink)
        }
        // CASE-INSENSITIVELY, because every one of these lists is matched
        // case-insensitively at use: "Accept" and "accept" are one label, and
        // declaring both is a mistake worth naming rather than a nuance.
        duplicates(inspected.map { $0.lowercased() }).forEach { _ in
            sink.error(
                "duplicate-canvas-phrase", path, "A canvas phrase appears more than once.")
        }
    }
}
