//
//  AudioInputDevices.swift
//  MaryVoice
//
//  CoreAudio HAL view of the machine's audio inputs: enumeration for the
//  Settings picker, UID→ID resolution for binding a specific device to the
//  capture engine, and a hardware-change monitor so MicCapture can follow
//  devices as they come and go (a Continuity iPhone does both constantly).
//
//  UIDs are the persistence key — AudioDeviceIDs are transient and change
//  across reconnects.
//

import CoreAudio
import Foundation

/// One input-capable audio device as the HAL reports it.
public struct AudioInputDevice: Identifiable, Sendable, Equatable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transportType: UInt32

    /// A Continuity Capture device — an iPhone acting as mic/camera.
    public var isContinuityCapture: Bool {
        transportType == kAudioDeviceTransportTypeContinuityCaptureWired
            || transportType == kAudioDeviceTransportTypeContinuityCaptureWireless
    }

    /// AirPods or any other Bluetooth headset.
    public var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

public enum AudioInputDeviceList {

    /// Every device with at least one input channel, in HAL order.
    public static func all() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  let uid = stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID)
            else { return nil }
            let name = stringProperty(of: id, selector: kAudioObjectPropertyName) ?? uid
            return AudioInputDevice(
                id: id,
                uid: uid,
                name: name,
                transportType: transportType(of: id))
        }
    }

    /// Resolve a persisted UID to the device's CURRENT transient ID.
    /// nil when the device is not present right now.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { id in
            inputChannelCount(of: id) > 0
                && stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID) == uid
        }
    }

    /// Whether a live device ID is an iPhone acting as mic (Continuity
    /// Capture). MicCapture asks per-start: Apple voice processing on these
    /// either initializes dead or fails outright (measured live).
    public static func isContinuityCapture(_ id: AudioDeviceID) -> Bool {
        let transport = transportType(of: id)
        return transport == kAudioDeviceTransportTypeContinuityCaptureWired
            || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
    }

    /// Whether a live device ID is a Bluetooth input. MicCapture asks per
    /// start for the same reason it asks about Continuity: Apple voice
    /// processing does not survive the route (see `MicCapture`).
    public static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let transport = transportType(of: id)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The stable key for a device the HAL is reporting right now.
    public static func uid(for id: AudioDeviceID) -> String? {
        stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID)
    }

    /// The built-in microphone's UID, if the machine has one. The standby
    /// wake listener prefers it over a wireless default so AirPods are not
    /// held on the call profile while Mary merely stands by.
    public static func builtInInputUID() -> String? {
        all().first { $0.transportType == kAudioDeviceTransportTypeBuiltIn }?.uid
    }

    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    // MARK: - HAL plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        var ids = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr
        else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else { return 0 }
        return value
    }

    private static func stringProperty(
        of id: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

/// Coalesced "the input hardware changed" callbacks: device list membership
/// and the system default input. MicCapture drives rebuilds from these; the
/// per-engine AVAudioEngineConfigurationChange notification covers the rest.
public final class AudioDeviceMonitor: @unchecked Sendable {

    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var listener: AudioObjectPropertyListenerBlock?
    private var addresses: [AudioObjectPropertyAddress] = []

    /// `onChange` fires on `queue` for every hardware-topology or
    /// default-input change. Call `stop()` (or let deinit) to unregister.
    public init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.queue = queue
        self.onChange = onChange
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onChange()
        }
        self.listener = listener
        addresses = [
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain),
        ]
        for i in addresses.indices {
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addresses[i], queue, listener)
        }
    }

    public func stop() {
        guard let listener else { return }
        for i in addresses.indices {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addresses[i], queue, listener)
        }
        self.listener = nil
    }

    deinit { stop() }
}
