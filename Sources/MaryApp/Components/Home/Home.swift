import Granite
import SwiftUI
import MaryRuntime

/// The single page of the app: the conversation with Mary flowing down one
/// sheet of paper, with the voice bar floating at the bottom.
struct Home: GraniteComponent {
    @Command var center: Center

    @Relay(.silence) var chat: ChatService
    @Relay(.silence) var config: ConfigService
}
