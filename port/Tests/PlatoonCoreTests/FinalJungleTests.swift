import XCTest
@testable import PlatoonCore

// Owner: section2. M5 navigator model (Game/Section2/FinalNavigator.swift) validated against the RE maze graph
// re/finaljungle/assets/maze_graph.json, with the maze read from the real section-2 data on re/platoon_port.adf.
// In-game checks (route at every room entry, host decoder == game decoder, drawn rooms) are headless:
// port/verify/section2/enh/run_enh.sh (PLATOON_S2NAV log).
final class FinalJungleTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func section2Memory() throws -> Memory {
        let adf = FinalJungleTests.root.appendingPathComponent("re/platoon_port.adf")
        guard FileManager.default.fileExists(atPath: adf.path) else { throw XCTSkip("no re/platoon_port.adf") }
        let disk = try Disk(contentsOf: adf)
        let mem = Memory()
        disk.loadTracks(first: 111, count: 48, to: 0x17000, memory: mem)   // section 2 = tracks 111..158 1:1
        return mem
    }

    private func graph() throws -> [String: Any] {
        let url = FinalJungleTests.root.appendingPathComponent("re/finaljungle/assets/maze_graph.json")
        guard let d = FileManager.default.contents(atPath: url.path) else { throw XCTSkip("no maze_graph.json") }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    func testMazeMatchesREGraph() throws {
        let maze = FinalJungleMaze(memory: try section2Memory())
        let g = try graph()
        let states = try XCTUnwrap(g["states"] as? [[String: Any]])
        let edges = try XCTUnwrap(g["edges"] as? [[String: Any]])
        let reach = maze.reachable()
        XCTAssertEqual(reach.count, states.count, "number of reachable (room, heading) states")
        var byKey: [String: FinalJungleMaze.State] = [:]
        for s in states {
            let room = try XCTUnwrap(s["room"] as? Int), dirs = UInt32(try XCTUnwrap(s["dirs"] as? String), radix: 16)!
            let st = FinalJungleMaze.State(room: room, dirs: dirs)
            XCTAssertNotNil(reach[st], "state \(st) of the RE graph is reachable")
            XCTAssertEqual(st.heading?.letter, s["compass"] as? String)
            XCTAssertEqual(maze.type(ofRoom: room), s["type"] as? Int)
            byKey["\(room)\(st.heading!.letter)"] = st
        }
        XCTAssertEqual(edges.count, reach.values.reduce(0) { $0 + $1.count }, "number of edges")
        for e in edges {
            let f = try XCTUnwrap(e["from"] as? [Any]), t = try XCTUnwrap(e["to"] as? [Any])
            let from = try XCTUnwrap(byKey["\(f[0])\(f[1])"]), to = try XCTUnwrap(byKey["\(t[0])\(t[1])"])
            let exit = FinalJungleMaze.Exit(rawValue: try XCTUnwrap(e["exit"] as? String))!
            XCTAssertEqual(maze.next(from, exit), to, "edge \(from) \(exit.rawValue)")
            XCTAssertTrue(maze.successors(from).contains { $0.exit == exit && $0.to == to })
        }
        let route = try XCTUnwrap(g["shortest_route_to_bunker"] as? [String])
        let start = FinalJungleMaze.State(room: FinalJungleMaze.startRoom, dirs: FinalJungleMaze.startDirs)
        XCTAssertEqual(maze.route(from: start)?.map(\.rawValue), route)
        let bunker = try XCTUnwrap(g["bunker_state"] as? [Any])
        var s = start
        for e in route { s = maze.next(s, FinalJungleMaze.Exit(rawValue: e)!) }
        XCTAssertEqual(s.room, bunker[0] as? Int); XCTAssertEqual(s.heading?.letter, bunker[1] as? String)
        XCTAssertTrue(maze.isBunker(s.room))
    }

    /// From every reachable state the BFS route really ends in a bunker room and is no longer than any other route
    /// (checked against a plain BFS distance map computed backwards).
    func testRoutesFromEveryStateAreShortest() throws {
        let maze = FinalJungleMaze(memory: try section2Memory())
        let reach = maze.reachable()
        var dist: [FinalJungleMaze.State: Int] = [:]
        for (s, _) in reach where maze.isBunker(s.room) { dist[s] = 0 }
        var changed = true
        while changed {
            changed = false
            for (s, succ) in reach where !maze.isBunker(s.room) {
                guard let d = succ.compactMap({ dist[$0.to] }).min() else { continue }
                if dist[s] == nil || d + 1 < dist[s]! { dist[s] = d + 1; changed = true }
            }
        }
        for (s, _) in reach {
            let r = try XCTUnwrap(maze.route(from: s), "route from \(s)")
            var x = s
            for e in r { XCTAssertTrue(maze.successors(x).contains { $0.exit == e }); x = maze.next(x, e) }
            XCTAssertTrue(maze.isBunker(x.room), "route from \(s) ends in a bunker")
            XCTAssertEqual(r.count, dist[s], "route from \(s) is shortest")
        }
        // every state reaches a bunker (the maze is a tree whose branches all end in a bunker, plus one loop)
        XCTAssertEqual(dist.count, reach.count)
    }

    func testHeadingsAndTimerBCD() {
        XCTAssertEqual(FinalJungleHeading(dirs: 0x010afff6), .north)
        XCTAssertEqual(FinalJungleHeading(dirs: 0x0afff601), .east)
        XCTAssertEqual(FinalJungleHeading(dirs: 0xfff6010a), .south)
        XCTAssertEqual(FinalJungleHeading(dirs: 0xf6010aff), .west)
        XCTAssertEqual(Platoon.s2_bcdTimer(seconds: 120), 0x0200)
        XCTAssertEqual(Platoon.s2_bcdTimer(seconds: 90), 0x0130)
        XCTAssertEqual(Platoon.s2_bcdTimer(seconds: 599), 0x0959)
        XCTAssertEqual(Platoon.s2_bcdTimer(seconds: 3599), 0x5959)
    }

    func testRendererDecodesEveryPicture() throws {
        let mem = try section2Memory()
        for pic in 1...10 {
            let planes = FinalJungleRenderer.decodePlanes(mem, picture: pic)
            XCTAssertEqual(planes.count, 4 * 0x2000)
            let px = FinalJungleRenderer.indexed(planes: planes)
            XCTAssertEqual(px.count, 320 * 144)
            XCTAssertGreaterThan(Set(px).count, 4, "picture \(pic) has content")
        }
        for t in 0...16 { XCTAssertEqual(FinalJungleRenderer.room(mem, roomType: t).count, 320 * 144) }
        XCTAssertEqual(FinalJungleRenderer.palette(mem)[1], 0xff448800)   // game palette colour 1 = $480
    }
}
