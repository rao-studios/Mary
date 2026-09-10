//
//  ChatService.swift
//  MaryRuntime
//
//  WHAT: Granite service shell for the chat page.
//  OUT:  ChatService+Center, Reducers/ChatService.Boot, .MirrorVoice
//

import Granite

package struct ChatService: GraniteService {
    @Service(.online) package var center: Center
    package init() {}
}
