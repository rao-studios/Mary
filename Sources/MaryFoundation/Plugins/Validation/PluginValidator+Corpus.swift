//
//  PluginValidator+Corpus.swift
//  MaryFoundation
//
//  WHAT: Corpus admission — compile regexes, closed StyleDimension/StyleValue, rule shape.
//  IN:   PluginValidator.validate / AbilityPackageValidator (package.corpus).
//  OUT:  SchemaIssue. Disk facts: corpus probe, not here.
//

import Foundation

public extension PluginValidator {

    /// Pattern-length cap. Crawl already caps input text; this caps the expression.
    static let maximumCorpusPatternLength = 400

    static func validateCorpus(
        _ corpus: PluginCorpusSchema,
        root: String,
        error: (String, String, String) -> Void
    ) {
        let path = "\(root).corpus"

        // Crawled corpus needs include. Structure corpora use the manifest, not extensions.
        if corpus.include.isEmpty, corpus.structure == nil {
            error(
                "corpus-includes-nothing",
                "\(path).include",
                "A corpus with no structure must name at least one file extension: one that matches nothing is a declaration that does nothing.")
        }
        for (index, extensionName) in corpus.include.enumerated()
        where extensionName.hasPrefix(".") || extensionName.isEmpty {
            error(
                "corpus-include-malformed",
                "\(path).include[\(index)]",
                "File extensions are written without a leading dot.")
        }

        for (index, marker) in corpus.projectMarkers.enumerated() {
            if marker.trimmingCharacters(in: .whitespaces).isEmpty {
                error(
                    "corpus-marker-empty",
                    "\(path).projectMarkers[\(index)]",
                    "A project marker names a file or folder that marks a root; an empty one matches nothing.")
            }
            // Marker is a name, not a path. Separators match nothing.
            if marker.contains("/") {
                error(
                    "corpus-marker-is-a-path",
                    "\(path).projectMarkers[\(index)]",
                    "A project marker is the NAME of an entry in the root directory, not a path to one.")
            }
        }

        if corpus.notation.trimmingCharacters(in: .whitespaces).isEmpty {
            error(
                "corpus-notation-missing",
                "\(path).notation",
                "A corpus names its notation in one word: it is the scope a style profile is filed under.")
        }

        // References need declarations. Else one hop then silence.
        if !corpus.relations.references.isEmpty, corpus.relations.declarations.isEmpty {
            error(
                "corpus-references-without-declarations",
                "\(path).relations.declarations",
                "References are resolved through the declarations index: declaring the first without the second makes every edge unresolvable.")
        }

        for (label, patterns) in [
            ("references", corpus.relations.references),
            ("ancestry", corpus.relations.ancestry),
            ("declarations", corpus.relations.declarations),
        ] {
            for (index, pattern) in patterns.enumerated() {
                validateCorpusPattern(
                    pattern, path: "\(path).relations.\(label)[\(index)]",
                    requiresCapture: true, error: error)
            }
        }

        for (index, rule) in corpus.style.enumerated() {
            validateCorpusStyleRule(rule, path: "\(path).style[\(index)]", error: error)
        }

        let budgets = corpus.budgets
        if budgets.maximumFiles < 1 || budgets.maximumEdges < 1 || budgets.maximumFileBytes < 1 {
            error(
                "corpus-budget-invalid",
                "\(path).budgets",
                "Every corpus budget is a positive count.")
        }

        if let structure = corpus.structure {
            validateCorpusStructure(structure, path: "\(path).structure", error: error)
        }
    }

    // MARK: - The project's shape on disk

    /// Structure must be actionable JSON. Disk facts belong to the corpus probe.
    static func validateCorpusStructure(
        _ structure: PluginCorpusStructureSchema,
        path: String,
        error: (String, String, String) -> Void
    ) {
        if structure.discovery == .directoryExtension,
           (structure.projectExtension ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            error(
                "corpus-structure-extension-missing",
                "\(path).projectExtension",
                "Discovery by directory extension needs the extension to look for.")
        }
        if let projectExtension = structure.projectExtension, projectExtension.hasPrefix(".") {
            error(
                "corpus-structure-extension-malformed",
                "\(path).projectExtension",
                "A project extension is written without a leading dot.")
        }
        // lockFile needs a path; without it every project reads "not open".
        if structure.openState.contains(.lockFile),
           (structure.lockFilePath ?? "").isEmpty {
            error(
                "corpus-structure-lock-path-missing",
                "\(path).lockFilePath",
                "An openState of lockFile needs the lock file's path, or the test can never find one.")
        }
        if structure.openState.isEmpty {
            error(
                "corpus-structure-open-state-empty",
                "\(path).openState",
                "A project declares how to tell it is open; an empty list answers nothing.")
        }

        validateCorpusManifest(
            structure.manifest, path: "\(path).manifest", error: error)

        for (index, part) in structure.parts.enumerated() {
            let partPath = "\(path).parts[\(index)]"
            if part.name.trimmingCharacters(in: .whitespaces).isEmpty {
                error(
                    "corpus-structure-part-unnamed",
                    "\(partPath).name",
                    "A part is named for what it holds — \"text\", \"synopsis\", \"annotations\".")
            }
            validateCorpusRelativePath(
                part.pathTemplate, path: "\(partPath).pathTemplate",
                mustSubstitute: "{id}", error: error)
        }

        if let template = structure.documentURLTemplate {
            // Unfilled placeholders refuse at read time.
            let remaining = template
                .replacingOccurrences(of: "{project}", with: "")
                .replacingOccurrences(of: "{id}", with: "")
            if remaining.contains("{") || remaining.contains("}") {
                error(
                    "corpus-structure-url-placeholder-unknown",
                    "\(path).documentURLTemplate",
                    "A document URL fills {project} and {id}; any other placeholder is left in the URL and never opens.")
            }
        }

        if let prefix = structure.handlePrefix, prefix.count != 1 {
            error(
                "corpus-structure-handle-prefix-invalid",
                "\(path).handlePrefix",
                "A handle prefix is one letter — it is the letter a spoken reference mints under, as in \"[D3]\".")
        }

        var seenActs: Set<PluginCorpusCeremony.Act> = []
        for (index, ceremony) in structure.ceremonies.enumerated() {
            let ceremonyPath = "\(path).ceremonies[\(index)]"
            if ceremony.menuPath.isEmpty {
                error(
                    "corpus-structure-ceremony-pathless",
                    "\(ceremonyPath).menuPath",
                    "A ceremony is coordinates to a command: with no menu path there is nothing to choose.")
            }
            for (level, title) in ceremony.menuPath.enumerated()
            where title.trimmingCharacters(in: .whitespaces).isEmpty {
                error(
                    "corpus-structure-ceremony-level-empty",
                    "\(ceremonyPath).menuPath[\(level)]",
                    "Every level of a menu path names a menu; an empty one matches nothing.")
            }
            // Duplicate ceremony for one act — reader would take the first.
            if !seenActs.insert(ceremony.act).inserted {
                error(
                    "corpus-structure-ceremony-duplicated",
                    "\(ceremonyPath).act",
                    "This package already declares a \(ceremony.act.rawValue) ceremony; two paths for one act means one of them is never used.")
            }
        }
    }

    static func validateCorpusManifest(
        _ manifest: PluginCorpusManifest,
        path: String,
        error: (String, String, String) -> Void
    ) {
        switch manifest.kind {
        case .xmlManifest:
            // Item id joins outline to disk. Missing id parses but opens nothing.
            let required: [(String, String?)] = [
                ("pathTemplate", manifest.pathTemplate),
                ("rootElement", manifest.rootElement),
                ("itemElement", manifest.itemElement),
                ("idAttribute", manifest.idAttribute),
            ]
            for (name, value) in required
            where (value ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                error(
                    "corpus-manifest-incomplete",
                    "\(path).\(name)",
                    "An XML manifest is read by name: without \(name) the outline cannot be found or has no items to find.")
            }
            if let template = manifest.pathTemplate {
                validateCorpusRelativePath(
                    template, path: "\(path).pathTemplate",
                    mustSubstitute: nil, error: error)
            }

        case .fileSystemTree:
            // fileSystemTree ignores element names. Declaring them is inert.
            let ignored: [(String, String?)] = [
                ("pathTemplate", manifest.pathTemplate),
                ("rootElement", manifest.rootElement),
                ("itemElement", manifest.itemElement),
                ("idAttribute", manifest.idAttribute),
                ("titleElement", manifest.titleElement),
                ("childrenElement", manifest.childrenElement),
                ("typeAttribute", manifest.typeAttribute),
            ]
            for (name, value) in ignored where value != nil {
                error(
                    "corpus-manifest-field-ignored",
                    "\(path).\(name)",
                    "A fileSystemTree outline IS the directory tree: \(name) is never read, so declaring it describes behaviour this package does not get.")
            }
        }

        // Trash type must appear in the kind list. Spelling vs disk is the probe.
        for (name, value) in [
            ("draftType", manifest.draftType), ("trashType", manifest.trashType),
        ] {
            if let value, value.trimmingCharacters(in: .whitespaces).isEmpty {
                error(
                    "corpus-manifest-type-empty",
                    "\(path).\(name)",
                    "An empty \(name) matches no item and quietly does nothing.")
            }
        }
    }

    /// Paths that leave the project fail at admission, not mid-ceremony.
    static func validateCorpusRelativePath(
        _ template: String,
        path: String,
        mustSubstitute placeholder: String?,
        error: (String, String, String) -> Void
    ) {
        if template.trimmingCharacters(in: .whitespaces).isEmpty {
            error(
                "corpus-structure-path-empty",
                path,
                "A path template names a file beneath the project root.")
            return
        }
        if template.hasPrefix("/") || template.hasPrefix("~") {
            error(
                "corpus-structure-path-absolute",
                path,
                "Corpus paths are relative to the project root: an absolute one is machine-local and reads the same file on every project.")
        }
        // `..` in a template is refused even if it would resolve inside.
        if template.split(separator: "/").contains("..") {
            error(
                "corpus-structure-path-traverses",
                path,
                "A path template does not climb out of the project; the reader refuses the resolved path anyway, and here it is still fixable.")
        }
        if let placeholder, !template.contains(placeholder) {
            error(
                "corpus-structure-path-not-per-item",
                path,
                "This template is the same file for every item: it needs \(placeholder) to name which one.")
        }
    }

    // MARK: - One rule

    static func validateCorpusStyleRule(
        _ rule: PluginCorpusStyleRule,
        path: String,
        error: (String, String, String) -> Void
    ) {
        if StyleDimension(rawValue: rule.dimension) == nil {
            error(
                "corpus-unknown-dimension",
                "\(path).dimension",
                "\"\(rule.dimension)\" is not a style dimension Mary knows; a rule naming one that does not exist can never be read.")
        }

        func checkValue(_ value: String, at valuePath: String) {
            if StyleValue(rawValue: value) == nil {
                error(
                    "corpus-unknown-style-value",
                    valuePath,
                    "\"\(value)\" is not a style value Mary knows.")
            }
        }

        if let condition = rule.guardCondition {
            validateCorpusCounter(
                condition.numerator, path: "\(path).guard.numerator", error: error)
            if let denominator = condition.denominator {
                validateCorpusCounter(
                    denominator, path: "\(path).guard.denominator", error: error)
            }
        }

        switch rule.kind {
        case .vote:
            if rule.candidates.count < 2 {
                error(
                    "corpus-vote-needs-alternatives",
                    "\(path).candidates",
                    "A vote decides between at least two candidates; with fewer there is nothing to decide and the file always votes the same way.")
            }
            for (index, candidate) in rule.candidates.enumerated() {
                checkValue(candidate.value, at: "\(path).candidates[\(index)].value")
                if candidate.counters.isEmpty {
                    error(
                        "corpus-candidate-counts-nothing",
                        "\(path).candidates[\(index)].counters",
                        "A candidate with no counters can never receive a vote.")
                }
                for (counterIndex, counter) in candidate.counters.enumerated() {
                    validateCorpusCounter(
                        counter,
                        path: "\(path).candidates[\(index)].counters[\(counterIndex)]",
                        error: error)
                }
            }

        case .ratio:
            guard let numerator = rule.numerator, let denominator = rule.denominator,
                  rule.threshold != nil
            else {
                error(
                    "corpus-ratio-incomplete",
                    path,
                    "A ratio rule needs a numerator, a denominator and a threshold.")
                return
            }
            validateCorpusCounter(numerator, path: "\(path).numerator", error: error)
            validateCorpusCounter(denominator, path: "\(path).denominator", error: error)
            if rule.above == nil, rule.below == nil {
                error(
                    "corpus-ratio-decides-nothing",
                    path,
                    "A ratio rule votes above its threshold, below it, or both — with neither it computes a number and discards it.")
            }
            if let above = rule.above { checkValue(above, at: "\(path).above") }
            if let below = rule.below { checkValue(below, at: "\(path).below") }

        case .vocabulary:
            guard let counter = rule.vocabulary else {
                error(
                    "corpus-vocabulary-incomplete",
                    path,
                    "A vocabulary rule needs a vocabulary counter.")
                return
            }
            if counter.source != .declaredTypeSuffix {
                error(
                    "corpus-vocabulary-source-invalid",
                    "\(path).vocabulary.source",
                    "A vocabulary is gathered from declared names: the counter's source must be declaredTypeSuffix.")
            }
            validateCorpusCounter(counter, path: "\(path).vocabulary", error: error)
        }
    }

    // MARK: - One counter

    static func validateCorpusCounter(
        _ counter: PluginCorpusCounter,
        path: String,
        error: (String, String, String) -> Void
    ) {
        switch counter.source {
        case .pattern, .selfReference:
            guard let pattern = counter.pattern, !pattern.isEmpty else {
                error(
                    "corpus-counter-pattern-missing",
                    "\(path).pattern",
                    "A \(counter.source.rawValue) counter needs a pattern.")
                return
            }
            // selfReference must capture a name.
            validateCorpusPattern(
                pattern, path: "\(path).pattern",
                requiresCapture: counter.source == .selfReference, error: error)

        case .declaredTypeSuffix:
            if counter.tokens.isEmpty {
                error(
                    "corpus-counter-tokens-missing",
                    "\(path).tokens",
                    "A declaredTypeSuffix counter needs at least one token.")
            }

        case .declaration, .fileBytes:
            break
        }
    }

    // MARK: - One pattern

    static func validateCorpusPattern(
        _ pattern: String,
        path: String,
        requiresCapture: Bool,
        error: (String, String, String) -> Void
    ) {
        if pattern.count > maximumCorpusPatternLength {
            error(
                "corpus-pattern-too-long",
                path,
                "A corpus pattern is at most \(maximumCorpusPatternLength) characters.")
            return
        }
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: pattern)
        } catch let compileFailure {
            // Named catch — bare `error` would shadow the reporting closure.
            error(
                "corpus-pattern-invalid",
                path,
                "This is not a valid regular expression, so the rule could never run: \(compileFailure.localizedDescription)")
            return
        }
        if requiresCapture, expression.numberOfCaptureGroups < 1 {
            error(
                "corpus-pattern-needs-capture",
                path,
                "This pattern must capture the name it finds: a match with no capture group says something is there without saying what.")
        }
    }
}
