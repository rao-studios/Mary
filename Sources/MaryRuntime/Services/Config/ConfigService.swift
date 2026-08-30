//
//  ConfigService.swift
//  MaryRuntime
//
//  WHAT: Granite service shell for Settings / persisted config.
//  OUT:  ConfigService+Center, Reducers/ConfigService.Update
//

import Granite

package struct ConfigService: GraniteService {
    @Service(.online) package var center: Center
    package init() {}
}
