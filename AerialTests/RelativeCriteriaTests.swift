import Testing
@testable import Aerial

/// Дерево черт, метки и подборки «Духовных родственников» (как `RelativeCriteriaTest`, `RelativeShadesTest`,
/// `RelativeRankerTest` ТВ).
struct RelativeCriteriaTests {
    private let hereditary = ["low_drone": 3, "creeping_unease": 3, "mental_unraveling": 3, "raw_acting": 3, "dead_silence": 2, "unexplained": 2]

    @Test func treeIsConsistent() {
        #expect(RelativeCriteria.groups.count == 50)
        let keys = RelativeCriteria.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(RelativeCriteria.all.allSatisfy { c in RelativeCriteria.groups.contains { $0.key == c.group } })
    }

    @Test func labelDropsFreeText() {
        #expect(RelativeCriteria.label(["переживание утраты ребёнка", " Jump_Scares ", "jump_scares"], english: false) == "Резкие пугалки")
        #expect(RelativeCriteria.label(["loss of a child"], english: false) == "")
    }

    @Test func shadesCoverEveryTrait() {
        #expect(Set(RelativeShades.ru.keys) == Set(RelativeCriteria.all.map(\.key)))
        #expect(RelativeShades.ru.values.allSatisfy { $0.count == 30 })
    }

    @Test func tagsFromDifferentGroupsAndStable() {
        let smile = ["jump_scares": 3, "low_drone": 3, "creeping_unease": 2]
        #expect(RelativeShades.tags("x", smile, english: true) == ["jump scares", "low drone"])
        #expect(RelativeShades.tags("x", ["low_drone": 3, "creaks_whispers": 3], english: true).count == 1)
        #expect(RelativeShades.label("tmdb:movie:1", smile, english: false) == RelativeShades.label("tmdb:movie:1", smile, english: false))
    }

    @Test func kinByOneSideGetsItsOwnRow() {
        func c(_ id: String, _ p: [String: Int]) -> RelativeRanker.Candidate { .init(id: id, profile: p, votes: 500, overused: 0) }
        let lookalikes = (1...12).map { c("look\($0)", ["raw_acting": 3, "creeping_unease": 3, "unexplained": 2, "dead_silence": 2]) }
        let minds = (1...4).map { c("mind\($0)", ["mental_unraveling": 2, "creeping_unease": 2, "quiet_acting": 2]) }
        let smile = c("smile", ["low_drone": 3, "mental_unraveling": 3, "jump_scares": 3])
        let sides = RelativeRanker.sides(hereditary, lookalikes + minds + [smile])
        let homes = sides.filter { $0.1.contains { $0.id == "smile" } }.map(\.0)
        #expect(homes.count == 1 && ["psychology", "sound_design"].contains(homes[0]))
    }
}
