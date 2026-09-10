import Foundation

/// What stopped the PEM reader.
///
/// Every payload is one of the decoder's OWN constants — never a substring
/// of the file. A file's header can claim any cipher name, and an unknown one
/// is reported as `"unknown"` rather than echoed: the payload ends up in a
/// user-visible message and in the command the failure surface offers, so a
/// file must not be able to write either.
public enum PEMReadFailure: Equatable, Sendable {
    /// A symmetric cipher the stack does not carry: `"DES-EDE3-CBC"`,
    /// `"DES-CBC"`, `"RC2-CBC"`, or `"unknown"`.
    case cipher(String)
    /// A password-based encryption scheme that is not PBES2 with PBKDF2:
    /// `"PBES1"`, `"PKCS#12"`, `"scrypt"`, or `"unknown"`.
    case scheme(String)
    /// A key algorithm the reader does not build: `"DSA"`,
    /// `"multi-prime RSA"`, or `"unknown"`.
    case keyType(String)
    /// A PuTTY `.ppk` file. Not PEM at all, but it is the other format that
    /// is on people's disks, and naming it costs one line.
    case putty
    /// The armor, the base64 or the DER did not hold together.
    case malformed
}
