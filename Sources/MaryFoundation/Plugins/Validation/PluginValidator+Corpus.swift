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

        // ⚠️ A STRUCTURED CORPUS ENUMERATES FROM ITS MANIFEST, so `include`
        // means nothing to it. The rule below is right for a corpus that IS a
        // body of files — it is walked by extension, and one matching nothing
        // does nothing — and wrong for a project with an outline, where the
        // manifest names the items and their extensions are an implementation
        // detail of where the text is stored.
        //
        // Requiring it anyway made `scrivener.mary` declare `include: ["rtf"]`
        // to satisfy a check, which read as a claim to participate in the
        // style crawl that this build cannot honour: the crawl walks a
        // directory, and inside a project it would find `Files/Data/{uuid}/
        // content.rtf` — units named by UUID, indexed as RTF markup rather
        // than prose. An inert claim is still a claim.
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
