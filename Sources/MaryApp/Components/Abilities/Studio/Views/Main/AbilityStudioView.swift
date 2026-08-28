import MaryBrain
import SwiftUI

struct AbilityStudioView: View {
    @Environment(\.openWindow) var openWindow
    @StateObject var model = AbilityStudioViewModel()
    @State var showsNewPackageSheet = false

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { model.selectedPackageID },
                set: { model.select($0) }
            )) {
                ForEach(model.snapshot.records) { record in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.package.ability.title)
                            // Show the Ability role, application affinity, and
                            // any extended discipline in one comparable line.
                            Text(Self.paradigmDetail(record.package))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(record.package.package.version.rawValue) · \(provenanceLabel(record))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } icon: {
                        Circle()
                            .fill(Color.maryAbilityTint(
                                record.package.ability.tint, fallback: .accentColor))
                            .frame(width: 9, height: 9)
                    }
                    .tag(record.id)
                }
            }
            .navigationTitle("Abilities")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("New…") { showsNewPackageSheet = true }
                        .disabled(model.isDirty)
                    Button("Import", action: model.importPackage)
                    Button("Reload", action: model.reload)
                    Spacer()
                }
                .padding(10)
                .background(.bar)
            }
        } detail: {
            if let record = model.selectedRecord {
                detail(record)
            } else {
                ContentUnavailableView(
                    "No Abilities",
                    systemImage: "shippingbox",
                    description: Text("Add a .mary package to the Abilities folder or import one here."))
            }
        }
        .frame(minWidth: 920, minHeight: 640)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showsNewPackageSheet) {
            AbilityStudioNewPackageSheet(model: model)
        }
    }

}
