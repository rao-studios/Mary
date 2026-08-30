//
//  VoiceService.swift
//  MaryRuntime
//
//  WHAT: Granite service shell for the voice session.
//  OUT:  VoiceService+Center, Reducers/VoiceService.Session
//

import Granite

package struct VoiceService: GraniteService {
    @Service(.online) package var center: Center
    package init() {}
}
