/// One block of a backend's connection form (M22).
///
/// The order is data because the alternative — hand-placing views per
/// backend — is what let S3's credential block go missing silently. A Core
/// test can assert that a mode's blocks cover the descriptor's schemas; it
/// cannot assert anything about views someone forgot to write.
public enum FormBlock: Sendable, Equatable {
    case schema(ConnectionFieldSchema)
    /// Where the Manual / login-set switcher goes.
    case loginModeSwitcher
    /// Substitutes the credential schema once a login set is chosen — the
    /// set supplies those values, so asking for them again would be wrong.
    case loginSetPicker
}

extension BackendDescriptor {
    public func formBlocks(usingLoginSet: Bool) -> [FormBlock] {
        [.schema(connectionSchema),
         .loginModeSwitcher,
         usingLoginSet ? .loginSetPicker : .schema(credentialSchema)]
    }
}
