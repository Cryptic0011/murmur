import AppKit
import Foundation
import Testing
@testable import Murmur

@Suite("Paster clipboard snapshot")
@MainActor
struct PasterClipboardTests {
    private func withScratchPasteboard(_ body: (NSPasteboard) -> Void) {
        let pb = NSPasteboard(name: .init("com.murmur.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        body(pb)
    }

    @Test("multi-item rich clipboard round-trips")
    func roundTrip() {
        withScratchPasteboard { pb in
            let first = NSPasteboardItem()
            first.setString("plain", forType: .string)
            first.setData(Data("<b>rich</b>".utf8), forType: .html)
            let second = NSPasteboardItem()
            second.setString("second", forType: .string)
            pb.clearContents()
            pb.writeObjects([first, second])

            let snapshot = Paster.snapshot(pb)
            pb.clearContents()
            pb.setString("dictated", forType: .string)
            Paster.restore(snapshot, to: pb, ifChangeCountStill: pb.changeCount)

            let items = pb.pasteboardItems ?? []
            #expect(items.count == 2)
            #expect(items.first?.string(forType: .string) == "plain")
            #expect(items.first?.data(forType: .html) == Data("<b>rich</b>".utf8))
            #expect(items.last?.string(forType: .string) == "second")
        }
    }

    @Test("a concealed clipboard (password manager copy) restores with all its types")
    func concealedRoundTrip() {
        withScratchPasteboard { pb in
            let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            let item = NSPasteboardItem()
            item.setString("hunter2", forType: .string)
            item.setString("1Password", forType: concealed)
            pb.clearContents()
            pb.writeObjects([item])

            let snapshot = Paster.snapshot(pb)
            pb.clearContents()
            pb.setString("dictated", forType: .string)
            Paster.restore(snapshot, to: pb, ifChangeCountStill: pb.changeCount)

            #expect(pb.string(forType: .string) == "hunter2")
            #expect(pb.pasteboardItems?.first?.types.contains(concealed) == true)
        }
    }

    @Test("no restore once the clipboard changed again")
    func skipsRestoreAfterUserCopy() {
        withScratchPasteboard { pb in
            pb.clearContents()
            pb.setString("old", forType: .string)
            let snapshot = Paster.snapshot(pb)
            pb.clearContents()
            pb.setString("dictated", forType: .string)
            let murmurChange = pb.changeCount
            pb.clearContents()
            pb.setString("user copy", forType: .string)

            Paster.restore(snapshot, to: pb, ifChangeCountStill: murmurChange)
            #expect(pb.string(forType: .string) == "user copy")
        }
    }
}
