//
//  EmbeddingTestSupport.swift
//  BonnieAmbientTests
//
//  DETERMINISTIC VECTORS FOR CI. `NLEmbedding` output varies by OS build,
//  so every test speaks through this stub: engineered unit vectors keyed by
//  keyword, mirroring `SemanticAbilityRequestIndexTests`' fake. The real
//  model runs only in the opt-in calibration harness.
//
//  DOCUMENTED DUPLICATION ([Reorg] test phase 4): `CannedVectorizer` is the
//  ambient half of a pair whose brain half is `FakeVectorizer` inside
//  Packages/MaryBrain/Tests/BonnieBrainTests/SemanticAbilityRequestIndexTests.swift.
//  Test targets cannot import test targets and no new targets are allowed
//  (PackageLayeringTests reads the manifests). EDIT IN LOCKSTEP: a change to
//  the canning strategy here must be mirrored there.
//

import Foundation
@testable import MaryAmbient

/// First keyword contained in the text wins; unknown text vectorizes to
/// nothing, exactly like a word the real model has no asset for.
struct CannedVectorizer: AmbientTextVectorizer {
    var keywords: [(keyword: String, vector: [Float])]

    init(keywords: [(String, [Float])]) {
        self.keywords = keywords
    }

    func vector(for text: String) -> [Float]? {
        let lowered = text.lowercased()
        return keywords.first { lowered.contains($0.keyword) }?.vector
    }
}
