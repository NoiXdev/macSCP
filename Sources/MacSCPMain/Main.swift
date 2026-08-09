import MacSCPAppKit

/// The executable target: an entry point and nothing else. All app code
/// lives in `MacSCPAppKit`, where tests can reach it.
@main
struct Main {
    static func main() {
        AppMain.main()
    }
}
