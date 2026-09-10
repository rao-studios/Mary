import Granite
import SwiftUI
import MaryRuntime

/// The conversation page. Voice bar floats at the bottom.
struct Home: GraniteComponent {
    @Command var center: Center

    @Relay(.silence) var chat: ChatService
    @Relay(.silence) var config: ConfigService
}
