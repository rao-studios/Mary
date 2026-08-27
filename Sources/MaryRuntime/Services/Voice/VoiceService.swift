import Granite

package struct VoiceService: GraniteService {
    @Service(.online) package var center: Center
    package init() {}
}
