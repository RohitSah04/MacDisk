import CloudDiskKit

/// The app extension's entry point.
///
/// Everything that has to be true for a File Provider extension — concurrency, cancellation,
/// error codes the system can act on, mapping Drive objects to items — lives in
/// `CloudDiskFileProviderAgent` inside CloudDiskKit, where the app target can compile it too and a
/// test target can reach it. This subclass exists because `NSExtensionPrincipalClass` needs a class
/// in the extension's own binary.
final class FileProviderExtension: CloudDiskFileProviderAgent {}
