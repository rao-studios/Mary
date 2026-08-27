import Granite

package struct ChatService: GraniteService {
    @Service(.online) package var center: Center
    package init() {}
}
