import Foundation
import FileProvider

/// The File Provider extension entry point for CloudDisk.
///
/// `fileproviderd` instantiates one object per active domain and expects it to survive concurrent
/// calls, so this class is only a translation layer: it turns the protocol methods into calls on
/// `CloudDiskProviderCore` and turns the results back into a `Progress` plus a completion handler
/// that runs exactly once. Every Drive rule lives in the core, where it can be unit tested without
/// the file provider system involved.
///
/// The appex target subclasses this with an empty body; that subclass name is what the extension's
/// `NSExtensionPrincipalClass` points at.
open class CloudDiskFileProviderAgent: NSObject, NSFileProviderReplicatedExtension {

    public let domain: NSFileProviderDomain

    private let services: ProviderServices?
    private let core: CloudDiskProviderCore?
    private let setupFailure: Error?

    private let gate = NSLock()
    private var isInvalidated = false
    /// Weakly held, so a finished operation needs no bookkeeping to be forgotten.
    private let inFlight = NSHashTable<AnyObject>.weakObjects()

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain

        var built: ProviderServices?
        var failure: Error?
        do {
            built = try ProviderServices.make(config: CloudDiskConfig.current(), domain: domain)
        } catch {
            failure = error
        }
        self.services = built
        self.setupFailure = failure
        self.core = built.map { CloudDiskProviderCore(services: $0) }

        super.init()

        // A previous instance may have died between handing a file to the system and the system
        // unlinking it; the provider, not the system, owns those bytes.
        built?.sweepStaleTemporaryFiles()
    }

    // MARK: - Lifecycle

    open func invalidate() {
        gate.lock()
        isInvalidated = true
        let running = inFlight.allObjects
        gate.unlock()
        (running as? [any OperationCanceling])?.forEach { $0.cancelRunningWork() }
    }

    // MARK: - Enumeration

    open func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                         request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard let core else {
            throw ProviderErrorMapper.bridge(setupFailure ?? DriveError.misconfigured(
                detail: "CloudDisk's File Provider extension could not read its configuration."))
        }
        let kind = try core.enumeratorKind(for: containerItemIdentifier)
        return DriveEnumerator(kind: kind, services: try requireServices())
    }

    // MARK: - Metadata

    open func item(for identifier: NSFileProviderItemIdentifier,
                   request: NSFileProviderRequest,
                   completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let operation = ProviderOperation<NSFileProviderItem>(deliver: { result in
            switch result {
            case .success(let item):
                completionHandler(item, nil)
            case .failure(let error):
                completionHandler(nil, ProviderErrorMapper.bridge(error))
            }
        })
        register(operation)

        operation.start { [core] progress in
            guard let core else { throw try self.configurationError() }
            _ = progress
            return try await core.item(for: identifier)
        }
        return operation.progress
    }

    // MARK: - Download

    open func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                            version requestedVersion: NSFileProviderItemVersion?,
                            request: NSFileProviderRequest,
                            completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void)
        -> Progress {
        let operation = ProviderOperation<CloudDiskProviderCore.FetchedContent>(deliver: { result in
                switch result {
                case .success(let content):
                    completionHandler(content.url, content.item, nil)
                case .failure(let error):
                    completionHandler(nil, nil, ProviderErrorMapper.bridge(error))
                }
            })
        register(operation)

        operation.start { [core] progress in
            guard let core else { throw try self.configurationError() }
            return try await core.fetchContents(for: itemIdentifier, progress: progress)
        }
        return operation.progress
    }

    // MARK: - Upload

    open func createItem(basedOn itemTemplate: NSFileProviderItem,
                         fields: NSFileProviderItemFields,
                         contents url: URL?,
                         options: NSFileProviderCreateItemOptions = [],
                         request: NSFileProviderRequest,
                         completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields,
                                                       Bool, Error?) -> Void) -> Progress {
        let operation = ProviderOperation<CloudDiskProviderCore.WriteOutcome>(deliver: { result in
            switch result {
            case .success(let outcome):
                completionHandler(outcome.item, outcome.pendingFields, outcome.shouldFetchContent, nil)
            case .failure(let error):
                completionHandler(nil, fields, false, ProviderErrorMapper.bridge(error))
            }
        })
        register(operation)

        operation.start { [core] progress in
            guard let core else { throw try self.configurationError() }
            return try await core.create(basedOn: itemTemplate, fields: fields, contents: url,
                                         options: options, progress: progress)
        }
        return operation.progress
    }

    open func modifyItem(_ item: NSFileProviderItem,
                         baseVersion version: NSFileProviderItemVersion,
                         changedFields: NSFileProviderItemFields,
                         contents newContentsUrl: URL?,
                         options: NSFileProviderModifyItemOptions = [],
                         request: NSFileProviderRequest,
                         completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields,
                                                       Bool, Error?) -> Void) -> Progress {
        let operation = ProviderOperation<CloudDiskProviderCore.WriteOutcome>(deliver: { result in
            switch result {
            case .success(let outcome):
                completionHandler(outcome.item, outcome.pendingFields, outcome.shouldFetchContent, nil)
            case .failure(let error):
                completionHandler(nil, changedFields, false, ProviderErrorMapper.bridge(error))
            }
        })
        register(operation)

        operation.start { [core] progress in
            guard let core else { throw try self.configurationError() }
            return try await core.modify(item, baseVersion: version, changedFields: changedFields,
                                         contents: newContentsUrl, options: options, progress: progress)
        }
        return operation.progress
    }

    open func deleteItem(identifier: NSFileProviderItemIdentifier,
                         baseVersion version: NSFileProviderItemVersion,
                         options: NSFileProviderDeleteItemOptions = [],
                         request: NSFileProviderRequest,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        let operation = ProviderOperation<Void>(deliver: { result in
            switch result {
            case .success: completionHandler(nil)
            case .failure(let error): completionHandler(ProviderErrorMapper.bridge(error))
            }
        })
        register(operation)

        operation.start { [core] progress in
            guard let core else { throw try self.configurationError() }
            _ = progress
            try await core.delete(identifier: identifier, baseVersion: version, options: options)
        }
        return operation.progress
    }

    // MARK: - Reimport

    /// Called once the system has finished replaying on-disk items into the provider, which happens
    /// after a restart, a backup restore and the first mount of a new domain. Establishing the
    /// changes cursor here is what makes updates flow again without a full rescan.
    open func importDidFinish(completionHandler: @escaping () -> Void) {
        guard let core else {
            completionHandler()
            return
        }
        let operation = ProviderOperation<Void>(deliver: { _ in completionHandler() })
        register(operation)
        operation.start { _ in
            await core.importDidFinish()
        }
    }

    // MARK: - Bridging helpers

    private func requireServices() throws -> ProviderServices {
        guard let services else { throw try configurationError() }
        return services
    }

    /// A broken install has to be reported as the permanent failure it is, not retried forever.
    private func configurationError() throws -> Error {
        setupFailure ?? DriveError.misconfigured(
            detail: "CloudDisk's File Provider extension is missing its OAuth client id or shared keychain group.")
    }

    private func register(_ operation: any OperationCanceling) {
        gate.lock()
        let alreadyInvalidated = isInvalidated
        if !alreadyInvalidated { inFlight.add(operation as AnyObject) }
        gate.unlock()
        if alreadyInvalidated { operation.cancelRunningWork() }
    }
}

/// Anything the agent can cancel when the system discards this instance.
protocol OperationCanceling: AnyObject {
    func cancelRunningWork()
}

extension ProviderOperation: OperationCanceling {
    func cancelRunningWork() {
        progress.cancel()
    }
}
