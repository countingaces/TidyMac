import Foundation
import Darwin

struct BulkDirectoryEntry: Sendable {
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
}

// Enumerates a directory's children using the getattrlistbulk(2) Darwin syscall.
// One syscall returns a packed buffer of {name, object type, allocated size} for
// many entries — orders of magnitude faster than walking each child through
// Foundation's URL/FileManager layer.
//
// Buffer parsing is deliberately defensive: every field read is bounds-checked
// against the entry length, and pointer-arithmetic is byte-explicit instead of
// trusting imported C struct sizes.
enum BulkDirectoryReader {
    private static let bufferBytes = 64 * 1024

    private static let attrCmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let attrCmnName: UInt32          = 0x0000_0001
    private static let attrCmnObjType: UInt32       = 0x0000_0008
    private static let attrFileAllocSize: UInt32    = 0x0000_0004

    private static let vTypeDir: UInt32 = 2
    private static let vTypeLink: UInt32 = 5

    static func enumerate(at path: String) throws -> [BulkDirectoryEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        if fd < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }

        var attrs = attrlist()
        attrs.bitmapcount = 5  // ATTR_BIT_MAP_COUNT
        attrs.commonattr = attrCmnReturnedAttrs | attrCmnName | attrCmnObjType
        attrs.fileattr = attrFileAllocSize

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferBytes, alignment: 8)
        defer { buffer.deallocate() }

        var results = [BulkDirectoryEntry]()

        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, bufferBytes, 0)
            if count == -1 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }

            let bufferLimit = UnsafeRawPointer(buffer).advanced(by: bufferBytes)
            var entryPtr = UnsafeRawPointer(buffer)

            for _ in 0..<Int(count) {
                guard entryPtr.advanced(by: 4) <= bufferLimit else { break }

                let entryStart = entryPtr
                let length = entryStart.loadUnaligned(as: UInt32.self)

                // Minimum viable entry: 4-byte length + 20-byte attribute_set
                guard length >= 24 else { break }
                let entryEnd = entryStart.advanced(by: Int(length))
                guard entryEnd <= bufferLimit else { break }

                // attribute_set_t is 5 contiguous uint32s in this order:
                //   commonattr | volattr | dirattr | fileattr | forkattr
                let asStart = entryStart.advanced(by: 4)
                let commonReturned = asStart.loadUnaligned(as: UInt32.self)
                let fileReturned = asStart.advanced(by: 12).loadUnaligned(as: UInt32.self)

                var fp = asStart.advanced(by: 20)

                // ATTR_CMN_NAME — attrreference_t {int32 dataoffset, uint32 length}
                var name = ""
                if commonReturned & attrCmnName != 0 {
                    guard fp.advanced(by: 8) <= entryEnd else { break }
                    let nameRefStart = fp
                    let dataOffset = nameRefStart.loadUnaligned(as: Int32.self)
                    fp = fp.advanced(by: 8)

                    let nameStart = nameRefStart.advanced(by: Int(dataOffset))
                    if nameStart >= entryStart && nameStart < entryEnd {
                        name = String(cString: nameStart.assumingMemoryBound(to: CChar.self))
                    }
                }

                // ATTR_CMN_OBJTYPE — uint32 vtype
                var isDir = false
                var isLink = false
                if commonReturned & attrCmnObjType != 0 {
                    guard fp.advanced(by: 4) <= entryEnd else { break }
                    let raw = fp.loadUnaligned(as: UInt32.self)
                    isDir = (raw == vTypeDir)
                    isLink = (raw == vTypeLink)
                    fp = fp.advanced(by: 4)
                }

                // ATTR_FILE_ALLOCSIZE — int64 off_t. The kernel packs attributes
                // (no padding within or between groups per getattrlist(2)), so we
                // read at the current cursor without aligning. loadUnaligned
                // handles the misaligned address.
                var size: Int64 = 0
                if fileReturned & attrFileAllocSize != 0 {
                    if fp.advanced(by: 8) <= entryEnd {
                        let raw = fp.loadUnaligned(as: Int64.self)
                        // Sanity-clamp: real allocations fit in well under 1 EB
                        if raw > 0 && raw < 0x0040_0000_0000_0000 {
                            size = raw
                        }
                    }
                }

                if !name.isEmpty && name != "." && name != ".." {
                    results.append(BulkDirectoryEntry(
                        name: name,
                        isDirectory: isDir,
                        isSymbolicLink: isLink,
                        size: size
                    ))
                }

                entryPtr = entryEnd
            }
        }

        return results
    }

    @inline(__always)
    private static func aligned(_ ptr: UnsafeRawPointer, to alignment: Int) -> UnsafeRawPointer {
        let address = Int(bitPattern: ptr)
        let mask = alignment - 1
        let alignedAddress = (address + mask) & ~mask
        return UnsafeRawPointer(bitPattern: alignedAddress) ?? ptr
    }
}
