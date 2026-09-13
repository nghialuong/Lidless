import XCTest

final class DeadlineProcessRunnerTests: XCTestCase {
    func testDeadlineIncludesResidenceBeforeRunnerStarts() {
        let finished = expectation(description: "runner returns within entry deadline")
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = ProcessDeadline(after: 0.25)

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
            let result = DeadlineProcessRunner.run(
                executable: "/bin/sleep",
                arguments: ["1"],
                deadline: deadline
            )
            let elapsed = TimeInterval(
                DispatchTime.now().uptimeNanoseconds - started
            ) / 1_000_000_000
            XCTAssertEqual(result, .failure(.timedOut))
            XCTAssertLessThan(elapsed, 0.35)
            finished.fulfill()
        }

        wait(for: [finished], timeout: 1)
    }

    func testCancellationStopsChildBeforeReturning() {
        let finished = expectation(description: "cancelled child cannot mutate later")
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let cancelAt = DispatchTime.now().uptimeNanoseconds + 40_000_000

        DispatchQueue.global(qos: .userInitiated).async {
            let result = DeadlineProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; sleep 0.3; /usr/bin/touch '\(marker.path)'"],
                deadline: ProcessDeadline(after: 0.8),
                cancelled: {
                    DispatchTime.now().uptimeNanoseconds >= cancelAt
                }
            )
            XCTAssertEqual(result, .failure(.cancelled))
            Thread.sleep(forTimeInterval: 0.35)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            try? FileManager.default.removeItem(at: marker)
            finished.fulfill()
        }

        wait(for: [finished], timeout: 2)
    }
}
