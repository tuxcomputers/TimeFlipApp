@testable import TimeFlipApp
import Foundation
import Testing

/// # Workflow 09: a category through its whole life
///
/// **Preconditions:** a fresh database with only the seeded categories. Step 1 establishes that.
///
/// **What it covers:** the sequence the Categories tab drives, end to end against the real store:
/// create, put it on a face, rename it, budget it, retire it, bring it back. `CategoryStoreTests`
/// proves each write on its own and `CategoryEditRulesTests` proves each decision on its own; what
/// neither can show is that they compose. The interesting claims here are all about what *survives*
/// a step: a rename must not detach the face, and retiring must not lose the colour and limit that
/// reactivating is supposed to hand back.
///
/// The reactivate step deliberately goes through `CategoryEditRules.createDecision` rather than
/// calling `updateCategoryActive` directly. Reinstating a retired category is not a button of its
/// own anywhere in the app: it is only reachable by typing a name that collides with one, so the
/// collision decision is part of the path under test.
///
/// **What it does not cover:** no device is involved, so nothing here touches the mock. Each step
/// re-reads the category from the store rather than carrying it in a variable, which is both closer
/// to what the tab does on each render and the only way steps can share state, since swift-testing
/// builds a fresh suite value per test.
///
/// `time_entry` survival is asserted in `CategoryStoreTests` instead: nothing writes that table yet,
/// so proving it needs raw SQL that would sit oddly in a workflow.
@Suite(.serialized)
@MainActor
struct W09CategoryLifecycleWorkflow {
    private var harness: WorkflowHarness {
        .shared("09-category-lifecycle")
    }

    private static let originalName = "Client work"
    private static let renamedName = "ACME-123"
    /// A face with no seeded category of its own, so the assignment this workflow makes is the only
    /// thing that put anything there.
    private static let faceID: UInt8 = 5
    private static let dailyLimit = 120
    private static let colourID = 1

    /// The category this workflow is about, by whichever name it currently holds.
    private func current(_ name: String) throws -> CategoryRecord {
        try #require(harness.dataStore.findCategory(named: name), "no category named \"\(name)\"")
    }

    @Test func step1_aFreshDatabaseHoldsOnlyTheSeeds() async throws {
        try await harness.step("1-preconditions") {
            let names = harness.dataStore.loadCategories().map(\.name)
            try #require(names == ["Break", "Meeting"], "unexpected starting categories: \(names)")
            try #require(
                harness.dataStore.findCategory(named: Self.originalName) == nil,
                "this workflow's category must not already exist"
            )
        }
    }

    @Test func step2_creatingLandsItActiveWithNothingSetOnIt() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("2-create") {
            let decision = CategoryEditRules.createDecision(
                rawName: "  \(Self.originalName)  ",
                findCategories: harness.dataStore.findCategories(named:)
            )
            // The padding is normalised away before the lookup, so this is a clean insert.
            try #require(decision == .insert(name: Self.originalName), "got \(decision)")

            let newID = try #require(harness.dataStore.createCategory(name: Self.originalName))

            let created = try current(Self.originalName)
            #expect(created.id == newID)
            #expect(created.isActive)
            #expect(created.iconID == 0)
            #expect(created.colourID == 0)
            #expect(created.dailyLimitMinutes == 0)
        }
    }

    @Test func step3_itCanBePutOnAFace() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("3-assign-to-face") {
            let category = try current(Self.originalName)

            harness.dataStore.updateFaceCategory(faceID: Self.faceID, categoryID: category.id)

            let onFace = try #require(harness.dataStore.loadFaceCategories()[Self.faceID])
            #expect(onFace.id == category.id)
            #expect(onFace.name == Self.originalName)
        }
    }

    /// The rename warns that history will report the new name, which is only true because
    /// everything links by id. The same property is what keeps the face attached.
    @Test func step4_renamingKeepsTheFaceAttached() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("4-rename") {
            let before = try current(Self.originalName)
            let decision = CategoryEditRules.renameDecision(
                rawName: Self.renamedName,
                currentName: before.name,
                currentID: before.id,
                findCategory: harness.dataStore.findCategory(named:)
            )
            try #require(decision == .confirm(.plain(newName: Self.renamedName)), "got \(decision)")

            harness.dataStore.updateCategoryName(categoryID: before.id, name: Self.renamedName)

            let after = try current(Self.renamedName)
            #expect(after.id == before.id, "a rename must not make a new row")
            let onFace = try #require(harness.dataStore.loadFaceCategories()[Self.faceID])
            #expect(onFace.id == before.id)
            #expect(onFace.name == Self.renamedName, "the face reports the new name with nothing backfilled")
        }
    }

    @Test func step5_itCanBeBudgetedAndThenRetired() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("5-budget-and-retire") {
            let category = try current(Self.renamedName)
            let write = try #require(
                CategoryEditRules.dailyLimitWrite(typed: Self.dailyLimit, current: category.dailyLimitMinutes)
            )

            harness.dataStore.updateCategoryDailyLimit(categoryID: category.id, minutes: write)
            harness.dataStore.updateCategoryColour(categoryID: category.id, colourID: Self.colourID)
            harness.dataStore.updateCategoryActive(categoryID: category.id, isActive: false)

            let retired = try current(Self.renamedName)
            #expect(retired.isActive == false)
            #expect(retired.dailyLimitMinutes == Self.dailyLimit)
            #expect(retired.colourID == Self.colourID)
        }
    }

    /// Retiring drops it from what the tab offers for a new assignment, and takes it off the face it
    /// was on -- a face cannot be left showing a category nothing can pick. The row itself stays, so
    /// the history recorded against it still resolves.
    @Test func step6_retiredMeansHiddenFromTheListAndOffItsFace() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("6-retired-still-resolves") {
            let category = try current(Self.renamedName)
            let split = CategoryEditRules.partitioned(harness.dataStore.loadCategories())

            #expect(!split.active.contains { $0.id == category.id }, "no longer offered")
            #expect(split.inactive.contains { $0.id == category.id }, "still listed as retired")

            let onFace = try #require(harness.dataStore.loadFaceCategories()[Self.faceID])
            #expect(onFace.id == TimeFlipConstants.unassignedCategoryID, "the face is back on the sentinel")
        }
    }

    /// Typing the retired category's name is the only way back. The decision has to offer the
    /// reinstate choice rather than a plain insert, and taking it must return the same row with
    /// everything it was carrying, not a fresh one.
    @Test func step7_typingItsNameAgainOffersItBackIntact() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("7-reactivate") {
            let retired = try current(Self.renamedName)

            let decision = CategoryEditRules.createDecision(
                rawName: Self.renamedName,
                findCategories: harness.dataStore.findCategories(named:)
            )
            guard case .conflict(.inactive(let existing, let name)) = decision else {
                Issue.record("expected the reinstate choice, got \(decision)")
                return
            }
            #expect(existing.id == retired.id)
            #expect(name == Self.renamedName)

            // What the "Reactivate the old category" button does.
            harness.dataStore.updateCategoryActive(categoryID: existing.id, isActive: true)

            let restored = try current(Self.renamedName)
            #expect(restored.id == retired.id, "the same row, not a second one with the same name")
            #expect(restored.isActive)
            #expect(restored.dailyLimitMinutes == Self.dailyLimit, "its budget came back with it")
            #expect(restored.colourID == Self.colourID)
            #expect(
                harness.dataStore.loadFaceCategories()[Self.faceID]?.id == TimeFlipConstants.unassignedCategoryID,
                "what it carried comes back; the face it came off does not, since nothing recorded which one"
            )
            #expect(
                harness.dataStore.loadCategories().filter { $0.name == Self.renamedName }.count == 1,
                "reinstating must not leave a duplicate behind"
            )
        }
    }
}
