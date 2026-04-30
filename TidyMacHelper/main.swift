import Foundation

/// Entry point for the privileged helper. Sets up an NSXPCListener on
/// the Mach service name registered in our launchd plist, hands every
/// incoming connection to HelperTool for code-signing validation, and
/// runs the main run loop forever (KeepAlive in the launchd plist
/// will respawn us if we crash).
let listener = NSXPCListener(machServiceName: kTidyMacHelperMachServiceName)
let helper = HelperTool()
listener.delegate = helper
listener.resume()

// Block forever. launchd treats us as alive as long as this RunLoop
// keeps spinning; if we return from main(), launchd respawns us.
RunLoop.main.run()
