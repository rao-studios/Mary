//
//  StyleRendering.swift
//  MaryFoundation
//
//  THE ONLY PLACE A TENET BECOMES WORDS.
//
//  Every sentence below is a Mary-owned literal, selected by a closed enum
//  value. Nothing a profile carries is ever concatenated into model
//  instruction — not its statement, not its illustration, not a publisher
//  string. That is what makes the format safe to import: a hostile profile can
//  pick a different sentence from this file, and cannot write a new one.
//
//  It lives beside the enum on purpose. The safety property is "every closed
//  value maps to a literal we wrote", and a property like that is only
//  reviewable if the map and the vocabulary are read together — a
//  `switch` here with no `default` is what makes a new value impossible to add
//  without also writing its sentence.
//

import Foundation

public enum StyleRendering {

    /// The sentence for one tenet, or nil when it must not speak.
    ///
    /// Nil is the common case for imported, unverified, or unknown tenets, and
    /// callers treat it as "say nothing" rather than as an error.
    public static func sentence(for tenet: StyleTenet) -> String? {
        guard tenet.isRenderable else { return nil }
        if tenet.dimension == .roleVocabulary {
            return vocabularySentence(tenet.vocabulary)
        }
        return sentence(dimension: tenet.dimension, value: tenet.value)
    }

    /// A bounded word list interpolated into a Mary-owned template. The
    /// words are DATA — the user's own naming — and the sentence around them
    /// is ours.
    static func vocabularySentence(_ vocabulary: [String]) -> String? {
        let words = vocabulary.prefix(8)
        guard !words.isEmpty else { return nil }
        return "They name things with role words like \(words.joined(separator: ", "))."
    }

    /// EXHAUSTIVE ON PURPOSE — no `default`. A new dimension or value cannot
    /// compile until someone has written what it means in words, which is the
    /// review gate the whole trust model rests on.
    static func sentence(dimension: StyleDimension, value: StyleValue) -> String? {
        switch dimension {
        case .concurrencyPrimitive:
            switch value {
            case .lockBox:
                return "They hold synchronous shared state in lock boxes, not actors."
            case .actor:
                return "They hold shared state in actors."
            case .serialQueue:
                return "They serialize shared state onto a dispatch queue."
            default: return nil
            }
        case .stateExposure:
            switch value {
            case .privateBoxedState:
                return "They keep state private and boxed, exposing readers rather than properties."
            case .publishedProperties:
                return "They expose state as observable published properties."
            default: return nil
            }
        case .errorPosture:
            switch value {
            case .degradeHonestly:
                return "When something cannot be done they degrade honestly and say so, rather than throwing."
            case .throwToCaller:
                return "They throw errors to the caller rather than absorbing them."
            default: return nil
            }
        case .testNaming:
            switch value {
            case .sentence:
                return "Test names read as sentences describing the behaviour, not as testMethodName."
            case .camelCaseUnit:
                return "Test names are short camelCase unit names."
            default: return nil
            }
        case .testFramework:
            switch value {
            case .swiftTesting:
                return "Tests use swift-testing — @Test and #expect, not XCTest."
            case .xctest:
                return "Tests use XCTest."
            default: return nil
            }
        case .bindingStyle:
            switch value {
            case .guardEarlyReturn:
                return "They bind with guard and return early rather than nesting conditionals."
            case .nestedConditional:
                return "They bind with nested if-let conditionals."
            default: return nil
            }
        case .fileOrganization:
            switch value {
            case .extensionPerConcern:
                return "They split a type across files by concern, one extension per file."
            case .singleFileType:
                return "They keep a type and everything about it in one file."
            default: return nil
            }
        case .accessDefault:
            switch value {
            case .internalUnlessNeeded:
                return "Declarations stay internal unless something outside needs them."
            case .publicByDefault:
                return "Declarations are public by default."
            default: return nil
            }
        case .commentPosture:
            switch value {
            case .incidentAnchored:
                return "Comments explain the failure a decision prevents, not what the code says."
            case .apiDescriptive:
                return "Comments describe the API contract of each declaration."
            case .sparse:
                return "They comment sparingly and let the code speak."
            default: return nil
            }
        case .annotationHabit:
            switch value {
            case .annotatesHeavily:
                return "They keep a synopsis or notes beside most of what they write."
            case .annotatesSparingly:
                return "They leave the writing to stand on its own, with few notes beside it."
            default: return nil
            }
        case .titlingStyle:
            switch value {
            case .sentenceTitles:
                return "Sections are titled as phrases that say what happens in them."
            case .labelTitles:
                return "Sections carry short label titles rather than descriptions."
            default: return nil
            }
        case .sectionGranularity:
            switch value {
            case .manyShortSections:
                return "They work in many short sections rather than a few long ones."
            case .fewLongSections:
                return "They work in a few long sections rather than many short ones."
            default: return nil
            }
        case .roleVocabulary, .unknown:
            return nil
        }
    }

    /// The block handed to a coding brief, or to the coding prompt.
    ///
    /// Ordered by confidence so a budget cut drops the weakest claims first,
    /// and hard-capped in characters because the coding prompt has very little
    /// headroom left.
    public static func block(
        for tenets: [StyleTenet],
        limit: Int = 1_200,
        heading: String = "How this person writes code (learned from their own work):"
    ) -> String? {
        let sentences = tenets
            .filter(\.isRenderable)
            .sorted {
                $0.confidence == $1.confidence
                    ? $0.tenetKey < $1.tenetKey
                    : $0.confidence > $1.confidence
            }
            .compactMap(sentence(for:))
        guard !sentences.isEmpty else { return nil }

        var block = heading
        for sentence in sentences {
            let line = "\n- \(sentence)"
            guard block.count + line.count <= limit else { break }
            block += line
        }
        // Everything was dropped by the budget — say nothing rather than
        // emitting a bare heading.
        return block == heading ? nil : block
    }
}
