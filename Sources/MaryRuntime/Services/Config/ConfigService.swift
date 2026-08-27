import Granite

package struct ConfigService: GraniteService {
    @Service(.online) package var center: Center
    package init() {}
}
