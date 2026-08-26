import Testing
import Foundation
@testable import ZettyCore

/// A model with Home plus the named projects, all unpinned and awake.
private func model(_ names: [String]) -> WorkspaceModel {
    let model = WorkspaceModel(homeRoot: "/Users/test")
    for name in names { model.addProject(name: name, rootPath: "/tmp/\(name)", makeActive: false) }
    return model
}

private func names(_ model: WorkspaceModel) -> [String] {
    model.projects.map(\.name)
}

private func index(of name: String, in model: WorkspaceModel) -> Int {
    model.projects.firstIndex { $0.name == name }!
}

@Test func createSpaceRejectsBlankAndDuplicateNames() {
    let model = model([])
    #expect(model.createSpace(name: "Client Acme") != nil)
    #expect(model.createSpace(name: "   ") == nil)
    #expect(model.createSpace(name: "client acme") == nil)   // case-insensitive
    #expect(model.spaces.count == 1)
}

@Test func spacesRenderBelowPinnedAndUnpinnedProjects() {
    // `delta` is added BEFORE the Space members so the Space tier has to pull
    // them past it. Under the old pin-only ordering this reads
    // ["Home", "alpha", "delta", "beta", "gamma"], so the assertion below
    // fails if `regroup()` stops consulting `spaceID`.
    let model = model(["alpha", "delta", "beta", "gamma"])
    model.togglePin(at: index(of: "alpha", in: model))
    let space = model.createSpace(name: "Work")!
    model.assign(projectAt: index(of: "beta", in: model), to: space.id)
    model.assign(projectAt: index(of: "gamma", in: model), to: space.id)
    // Spaces sit BELOW Projects, so spaceless `delta` precedes the members.
    #expect(names(model) == ["Home", "alpha", "delta", "beta", "gamma"])
}

@Test func pinnedMemberFloatsToTopOfItsOwnSpaceNotTheWorkspace() {
    // Two Spaces, and the pin lands in the SECOND one. Old behavior floats a
    // pinned project to the global top — ["Home", "b2", "a1", "a2", "b1"] —
    // so this asserts the pin stays inside its own Space.
    let model = model(["a1", "a2", "b1", "b2"])
    let first = model.createSpace(name: "First")!
    let second = model.createSpace(name: "Second")!
    for name in ["a1", "a2"] {
        model.assign(projectAt: index(of: name, in: model), to: first.id)
    }
    for name in ["b1", "b2"] {
        model.assign(projectAt: index(of: name, in: model), to: second.id)
    }
    model.togglePin(at: index(of: "b2", in: model))
    #expect(names(model) == ["Home", "a1", "a2", "b2", "b1"])
}

@Test func updateSpaceAndCollapseMutateInPlace() {
    let model = model([])
    let space = model.createSpace(name: "Work")!
    model.updateSpace(id: space.id, colorID: "moss", glyph: "hammer.fill")
    model.setSpaceCollapsed(id: space.id, true)
    #expect(model.spaces[0].colorID == "moss")
    #expect(model.spaces[0].glyph == "hammer.fill")
    #expect(model.spaces[0].isCollapsed == true)
    #expect(model.spaces[0].name == "Work")   // appearance edits never rename
}

@Test func spacesRenderInSpacesArrayOrder() {
    let model = model(["a", "b"])
    let first = model.createSpace(name: "First")!
    let second = model.createSpace(name: "Second")!
    model.assign(projectAt: index(of: "a", in: model), to: second.id)
    model.assign(projectAt: index(of: "b", in: model), to: first.id)
    #expect(names(model) == ["Home", "b", "a"])
    model.moveSpace(from: 0, to: 1)
    #expect(names(model) == ["Home", "a", "b"])
}

@Test func assignRefusesHomeScratchAndClones() {
    let model = model(["src"])
    let space = model.createSpace(name: "Work")!
    #expect(model.assign(projectAt: index(of: "Home", in: model), to: space.id) == false)

    model.addScratchProject(makeActive: false)
    #expect(model.assign(projectAt: index(of: "scratch", in: model), to: space.id) == false)

    model.addCloneProject(name: "src/fork", rootPath: "/tmp/fork", cloneSource: "/tmp/src")
    #expect(model.assign(projectAt: index(of: "src/fork", in: model), to: space.id) == false)
}

@Test func assignRejectsAnUnknownSpaceID() {
    let model = model(["a"])
    #expect(model.assign(projectAt: index(of: "a", in: model), to: UUID()) == false)
    #expect(model.projects.first { $0.name == "a" }?.spaceID == nil)
}

@Test func cloneStaysGluedToASourceInsideASpace() {
    let model = model(["src", "other"])
    let space = model.createSpace(name: "Work")!
    model.assign(projectAt: index(of: "src", in: model), to: space.id)
    model.addCloneProject(name: "src/fork", rootPath: "/tmp/fork", cloneSource: "/tmp/src")
    // `other` is spaceless so it now precedes the Space block; the clone is
    // still glued directly beneath its source inside the Space.
    #expect(names(model) == ["Home", "other", "src", "src/fork"])
}

@Test func removingASpaceKeepsEveryProject() {
    let model = model(["a", "b"])
    let space = model.createSpace(name: "Work")!
    model.assign(projectAt: index(of: "a", in: model), to: space.id)
    model.removeSpace(id: space.id)
    #expect(model.spaces.isEmpty)
    #expect(names(model).sorted() == ["Home", "a", "b"])
    #expect(model.projects.allSatisfy { $0.spaceID == nil })
}

@Test func renameSpaceRejectsACollisionAndKeepsTheOldName() {
    let model = model([])
    let first = model.createSpace(name: "One")!
    _ = model.createSpace(name: "Two")
    #expect(model.renameSpace(id: first.id, to: "two") == false)
    #expect(model.space(named: "One") != nil)
    #expect(model.renameSpace(id: first.id, to: "Uno") == true)
    #expect(model.space(named: "uno") != nil)
}

@Test func moveProjectRejectsACrossSpaceMove() {
    let model = model(["a", "b"])
    let space = model.createSpace(name: "Work")!
    model.assign(projectAt: index(of: "a", in: model), to: space.id)
    let before = names(model)
    model.moveProject(from: index(of: "a", in: model), to: index(of: "b", in: model))
    #expect(names(model) == before)
}

@Test func hibernatedMemberKeepsItsSpaceMembership() {
    let model = model(["a"])
    let space = model.createSpace(name: "Work")!
    let i = index(of: "a", in: model)
    model.assign(projectAt: i, to: space.id)
    model.projects[i].isHibernated = true
    #expect(model.projects(inSpace: space.id).map(\.name) == ["a"])
}

// MARK: - effectiveSpaceID
//
// Regression coverage for I2: a clone's own `spaceID` is always nil (`assign`
// refuses clones), so it must resolve through its SOURCE to report/render the
// Space it's actually glued inside. These drive a real WorkspaceModel end to
// end, unlike SpaceCLITests' clone case, which hand-builds a StatusSnapshot
// whose clone row already carries its source's Space name and so never
// exercised this resolution rule at all.

@Test func effectiveSpaceIDResolvesACloneToItsSourcesSpace() {
    let model = model(["src"])
    let space = model.createSpace(name: "Work")!
    model.assign(projectAt: index(of: "src", in: model), to: space.id)
    model.addCloneProject(name: "src/fork", rootPath: "/tmp/fork", cloneSource: "/tmp/src")
    let clone = model.projects.first { $0.name == "src/fork" }!
    #expect(model.effectiveSpaceID(of: clone) == space.id)
}

@Test func effectiveSpaceIDResolvesNilForAnOrphanedClone() {
    let model = model(["src"])
    let space = model.createSpace(name: "Work")!
    model.assign(projectAt: index(of: "src", in: model), to: space.id)
    model.addCloneProject(name: "src/fork", rootPath: "/tmp/fork", cloneSource: "/tmp/src")
    model.removeProject(at: index(of: "src", in: model))   // source is gone; clone is now orphaned
    let clone = model.projects.first { $0.name == "src/fork" }!
    #expect(model.effectiveSpaceID(of: clone) == nil)
}

@Test func effectiveSpaceIDResolvesAnOrdinaryProjectsOwnSpace() {
    let model = model(["a"])
    let space = model.createSpace(name: "Work")!
    model.assign(projectAt: index(of: "a", in: model), to: space.id)
    let a = model.projects.first { $0.name == "a" }!
    #expect(model.effectiveSpaceID(of: a) == space.id)
}

@Test func effectiveSpaceIDResolvesNilForASpacelessOrdinaryProject() {
    let model = model(["a"])
    let a = model.projects.first { $0.name == "a" }!
    #expect(model.effectiveSpaceID(of: a) == nil)
}

@Test func effectiveSpaceIDResolvesNilForACloneWhoseSourceIsSpaceless() {
    let model = model(["src"])
    model.addCloneProject(name: "src/fork", rootPath: "/tmp/fork", cloneSource: "/tmp/src")
    let clone = model.projects.first { $0.name == "src/fork" }!
    #expect(model.effectiveSpaceID(of: clone) == nil)
}

@Test func hibernatedMembersSinkToTheBottomOfTheirSpace() {
    // Hibernation outranks pinning INSIDE a Space: awake-pinned, awake-unpinned,
    // hibernated-pinned, hibernated-unpinned. Fails if the tiers are dropped —
    // plain assign order here would be one, two, three, four.
    let model = model(["one", "two", "three", "four"])
    let space = model.createSpace(name: "Work")!
    for name in ["one", "two", "three", "four"] {
        model.assign(projectAt: index(of: name, in: model), to: space.id)
    }
    model.togglePin(at: index(of: "four", in: model))   // awake + pinned → very top
    model.togglePin(at: index(of: "two", in: model))    // will be dormant + pinned
    model.projects[index(of: "two", in: model)].isHibernated = true
    model.projects[index(of: "one", in: model)].isHibernated = true
    model.reapplyOrdering()
    #expect(names(model) == ["Home", "four", "three", "two", "one"])
}

@Test func aHibernatedCloneStaysGluedToItsAwakeSource() {
    // Gluing wins over the awake/dormant split — the attachment is the
    // load-bearing invariant, so a dormant clone does NOT sink past its source.
    let model = model(["src", "mate"])
    let space = model.createSpace(name: "Work")!
    model.assign(projectAt: index(of: "src", in: model), to: space.id)
    model.assign(projectAt: index(of: "mate", in: model), to: space.id)
    let clone = model.addCloneProject(name: "src/fork", rootPath: "/tmp/fork",
                                      cloneSource: "/tmp/src")
    clone.isHibernated = true
    model.reapplyOrdering()
    #expect(names(model) == ["Home", "src", "src/fork", "mate"])
}
