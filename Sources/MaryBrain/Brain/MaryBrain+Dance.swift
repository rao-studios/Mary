//
//  MaryBrain+Dance.swift
//  MaryBrain
//
//  WHAT: What the shader composer may know of the conversation.
//  IN:   MaryRuntime+BrainInstall (wires SeerShaderComposer)
//  OUT:  recentSpokenLines
//  PIN:  Spoken turns only, the same filter the follow-up lane uses; Skill
//        plumbing never reaches a prompt that paints.
//

import Foundation

extension MaryBrain {

    /// The last `limit` spoken lines, oldest first, as "you:" / "Mary:".
    package func recentSpokenLines(limit: Int = 6) -> [String] {
        spokenMessages().suffix(max(0, limit)).map { message in
            "\(message.role == "user" ? "they" : "Mary"): \(message.content)"
        }
    }
}
