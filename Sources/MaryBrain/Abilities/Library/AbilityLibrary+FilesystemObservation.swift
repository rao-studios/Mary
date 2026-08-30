//
//  AbilityLibrary+FilesystemObservation.swift
//  MaryBrain
//
//  WHAT: Watch Ability package directories for changes.
//  IN:   AbilityLibrary.swift
//  OUT:  reload → new snapshot
//
import ApplicationServices
import MaryFoundation
import CryptoKit
import Darwin
import Foundation
import os

extension AbilityLibrary {

    // MARK: - Filesystem observation

    /// Runs observer mutations on their owning queue. Reloads triggered by a
    /// directory source already execute there, so the queue-specific fast path
    /// also prevents a self-sync deadlock.
    func performOnObservationQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: observationQueueKey) != nil {
            work()
        } else {
            observationQueue.sync(execute: work)
        }
    }

    func refreshFilesystemObservation(
        for locations: [AbilityPackageLocation]
    ) {
        // `reload()` owns the transaction lock. Observer work can itself be waiting for that lock
        observationQueue.async { [weak self] in
            guard let self else { return }
            self.observedReloadWorkItem?.cancel()
            self.observedReloadWorkItem = nil
            self.directoryObservations.removeAll()

            var watched: [String: URL] = [:]
            for location in locations {
                guard let url = self.nearestExistingDirectory(to: location.directory) else {
                    continue
                }
                watched[url.standardizedFileURL.path] = url
            }
            for (path, url) in watched {
                self.directoryObservations[path] = DirectoryObservation(
                    url: url,
                    queue: self.observationQueue
                ) { [weak self] in
                    self?.scheduleObservedReload()
                }
            }

            // Close the small configure/re-arm race. Usually the byte
            // fingerprint is unchanged and this pass is a no-op.
            self.scheduleObservedReload(delay: 0)
        }
    }

    func nearestExistingDirectory(to desiredURL: URL) -> URL? {
        var candidate = desiredURL.standardizedFileURL
        var isDirectory = ObjCBool(false)
        while !fileManager.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory) || !isDirectory.boolValue {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
            isDirectory = false
        }
        return candidate
    }

    func scheduleObservedReload(delay: TimeInterval = 0.2) {
        let schedule = { [weak self] in
            guard let self else { return }
            observedReloadWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.reloadIfFilesystemChanged()
            }
            observedReloadWorkItem = item
            observationQueue.asyncAfter(
                deadline: .now() + delay,
                execute: item)
        }
        if DispatchQueue.getSpecific(key: observationQueueKey) != nil {
            schedule()
        } else {
            observationQueue.async(execute: schedule)
        }
    }

    func reloadIfFilesystemChanged() {
        transactionLock.lock(); defer { transactionLock.unlock() }
        let current: (locations: [AbilityPackageLocation], fingerprint: Data?) = {
            lock.lock(); defer { lock.unlock() }
            return (state.locations, state.filesystemFingerprint)
        }()
        guard current.fingerprint != fingerprint(of: current.locations) else {
            return
        }
        _ = reload()
    }

    /// Content-addresses every direct `.mary` file in every configured root, plus root existence and precedence.
    func fingerprint(
        of locations: [AbilityPackageLocation]
    ) -> Data {
        var hasher = SHA256()
        func update(_ value: String) {
            let bytes = Data(value.utf8)
            hasher.update(data: Data("\(bytes.count):".utf8))
            hasher.update(data: bytes)
        }
        func update(_ value: Data) {
            hasher.update(data: Data("\(value.count):".utf8))
            hasher.update(data: value)
        }

        for location in locations.sorted(by: {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.directory.standardizedFileURL.path
                < $1.directory.standardizedFileURL.path
        }) {
            let directory = location.directory.standardizedFileURL
            update(directory.path)
            update(String(describing: location.source))
            update(String(location.priority))
            var isDirectory = ObjCBool(false)
            let exists = fileManager.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory) && isDirectory.boolValue
            update(exists ? "directory" : "missing")
            guard exists,
                  let files = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles])
            else { continue }
            for file in files
                .filter({ $0.pathExtension.lowercased() == "mary" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                update(file.lastPathComponent)
                do {
                    update(try AbilityPackageCodec.contents(of: file))
                } catch {
                    // Oversized/unreadable files still need a stable change
                    // token so that replacing them can recover automatically.
                    let values = try? file.resourceValues(forKeys: [
                        .fileSizeKey,
                        .contentModificationDateKey,
                    ])
                    update("unreadable")
                    update(String(values?.fileSize ?? -1))
                    update(values?.contentModificationDate?.description ?? "no-date")
                }
            }
        }
        return Data(hasher.finalize())
    }

}
