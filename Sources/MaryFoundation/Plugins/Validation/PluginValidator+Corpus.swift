//
//  PluginValidator+Corpus.swift
//  MaryFoundation
//
//  THE CORPUS DECLARATION'S BOUNDS.
//
//  A corpus block is the one place a package hands Mary REGULAR EXPRESSIONS to
//  run, and that is what shapes every rule here.
//
//  COMPILATION IS NOT OPTIONAL. A pattern that does not compile is caught at
//  admission, in the validator, with a path pointing at the exact rule — not
//  at crawl time, six hours later, as a silently missing edge in a
//  neighbourhood nobody knew was incomplete. The whole class of "the corpus
//  quietly stopped learning" bug is closed here.
//
//  THE VOCABULARY IS CLOSED. `dimension` and `value` are strings on the wire
//  so this schema does not move every time the style vocabulary grows — which
//  means a typo is a string that matches nothing rather than a compiler error.
//  Checking them against `StyleDimension`/`StyleValue` at admission is what
//  turns "this rule silently never votes" into "this package does not load".
//
//  SHAPE, because the three rule kinds use disjoint halves of one struct: a
//  `vote` with no candidates and a `ratio` with no threshold are both
//  well-formed JSON that can never produce an observation, and a package whose
//  style block is inert should say so at admission rather than at inspection.
//

import Foundation

public extension PluginValidator {

    /// A pattern longer than this is refused. The crawl already caps the TEXT
    /// a pattern runs over; this caps the pattern itself, because
    /// pathological backtracking is a property of the expression and not of
    /// the input's size.
    static let maximumCorpusPatternLength = 400

    static func validateCorpus(
        _ corpus: PluginCorpusSchema,
        root: String,
        error: (String, String, String) -> Void
    ) {
        let path = "\(root).corpus"

        // A CRAWLED CORPUS MUST MATCH SOMETHING. A corpus with a `structure`
        // is reached through its manifest and part templates instead, so it
        // legitimately names no extension — and requiring one there would
        // make a package crawl a project's RTF as if it were prose.
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

        if corpus.notation.trimmingCharacters(in: .whitespaces).isEmpty {
            error(
                "corpus-notation-missing",
                "\(path).notation",
                "A corpus names its notation in one word: it is the scope a style profile is filed under.")
        }

        // THE CRAWL CANNOT RESOLVE A REFERENCE WITHOUT DECLARATIONS. References
        // name things; only the declarations probe says which file declares
        // one. A corpus with references and no declarations walks one hop and
        // then stops, quietly, which looks exactly like a small project.
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

    /// THE SAME BARGAIN AS A PATTERN, one layer out: a structure block is a
    /// claim about a directory nobody has looked in yet, and every field of it
    /// can be individually well-formed JSON while the whole says nothing a
    /// reader can act on. A manifest declared `xmlManifest` with no element
    /// names parses, admits, and then fails at the moment a user asks for
    /// their outline — which is the worst moment to find out, because by then
    /// they have asked for something.
    ///
    /// WHAT IS NOT CHECKED HERE is anything about the disk. Whether the
    /// project exists, whether the manifest is where the template says, and
    /// whether the element names match that file are facts about a real
    /// project, and they belong to `mary-corpus-probe project` rather than to
    /// admission. This checks only that the declaration COULD be satisfied.
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
        // A LOCK FILE IS THE ONE OPEN-STATE TEST THAT NEEDS COORDINATES. The
        // others read the process table; this one reads a path, and without it
        // the test silently answers "not open" for every project forever.
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
            // BRACES LEFT OVER AFTER SUBSTITUTION ARE A REFUSAL AT READ TIME,
            // so a placeholder nothing fills is a URL that never opens.
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
            // TWO CEREMONIES FOR ONE ACT is a package disagreeing with itself,
            // and the reader would silently take whichever came first.
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
            // THE ID IS THE JOIN between the outline and the text on disk. An
            // outline parsed without one reads perfectly and can open nothing
            // — the probe reports it as "88/88 ids present" precisely because
            // zero is the failure that looks like success.
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
            // THE TREE IS THE OUTLINE, so element names describe nothing and
            // are silently ignored at read time — a declaration that looks
            // like it is working and is not.
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

        // A TYPE THAT NAMES NOTHING IN THE LIST is the quiet version of the
        // same bug: the trash type decides what is excluded, and one spelled
        // differently from the manifest's excludes nothing at all. Only the
        // internal agreement is checkable here — whether "TrashFolder" is
        // really Scrivener's spelling is the probe's question.
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

    /// A declared path is refused at READ time if it leaves the project, and
    /// refusing it at admission instead turns a mid-ceremony failure into a
    /// package that does not load.
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
        // `..` INSIDE A TEMPLATE is refused even when it would resolve back
        // inside, because a template is written once and substituted many
        // times — the id decides where it lands.
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
            // A SELF-REFERENCE RESOLVES A NAME, so it must capture one — the
            // whole counter is "does this name appear in this file's own
            // declarations", and without a capture group there is no name.
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
            // NAMED, because the implicit `error` a bare `catch` binds would
            // shadow the reporting closure of the same name — and the shadow
            // compiles far enough to be confusing.
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
