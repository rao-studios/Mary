import AppKit
import MaryBrain
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Native actions stage

@MainActor
struct AbilityStudioActionsEditor: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    @State var selectedOperation = 0
    @State var showsPortableSkillImplementation = false

    var body: some View {
        AbilityStudioStageScroll(
            title: "Teach callable Remote Hands actions",
            introduction: "A callable action is one bounded visual recipe selected only after normal Ability and Skill routing. Reusable semantic-plan primitives live separately in Semantic Plans and can never become model tools.") {
            if let plugin = package.plugin {
                applicationIdentity(plugin)
                nativeFaculty(plugin)
                operations(plugin)
            } else {
                AbilityStudioEditorSection("Choose the implementation shape", symbol: "hand.point.up.left") {
                    Label("No package-carried application recipe", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text("That is correct for an Ability that binds an installed compiled faculty. Add Remote Hands only when this file itself needs to teach Mary how to operate an application through bounded visible-control blocks.")
                        .foregroundStyle(.secondary)
                    Button("Add Remote Hands Faculty") { addPluginPlugin() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showsPortableSkillImplementation) {
            if let draft = model.draftPackage, draft.plugin != nil {
                AbilityStudioPortableSkillImplementationSheet(
                    model: model,
                    package: draft,
                    onCreated: selectCreatedOperation)
            }
        }
    }

}
