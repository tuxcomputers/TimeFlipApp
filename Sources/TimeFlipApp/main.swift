import Foundation

// The whole app, at this point in the rebuild: make sure the database is there and matches the
// schema, say what happened, and exit. No window, no menu bar, no radio -- those arrive as the
// modules that need them are written.
//
// It exits rather than staying resident on purpose, so this step can be run and re-run from a
// terminal and the second run observably does nothing the first did not already do.

do {
    let outcome = try DatabaseBootstrap.ensureDatabase()
    print("database: \(outcome.databaseURL.path)")
    print(outcome.createdDatabase ? "created it" : "already existed")
    print("applied \(outcome.filesApplied.count) file(s): \(outcome.filesApplied.joined(separator: ", "))")
    exit(EXIT_SUCCESS)
} catch {
    // stderr, and a non-zero exit: a database that could not be brought up is not something to
    // mention in passing on the way to carrying on regardless.
    let message = (error as? DatabaseBootstrap.Failure)?.description ?? error.localizedDescription
    FileHandle.standardError.write(Data("timeflip: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}
