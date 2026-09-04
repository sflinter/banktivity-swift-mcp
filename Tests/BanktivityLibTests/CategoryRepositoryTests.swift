// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("CategoryRepository", .serialized)
struct CategoryRepositoryTests {

    @Test("create stores categories as Category entities")
    func createUsesCategoryEntity() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        _ = try TestVaultHelper.seedCurrencies(in: vault.container)

        let repo = CategoryRepository(container: vault.container)
        let category = try repo.create(name: "Tax Root", type: "expense")

        #expect(category.name == "Tax Root")
        #expect(category.fullName == "Tax Root")
        #expect(category.type == "expense")

        let storedEntityName = try fetchCategoryEntityName(id: category.id, in: vault.container)
        #expect(storedEntityName == "Category")
        #expect(try repo.auditCategoryEntities().isEmpty)
    }

    @Test("create supports nested category paths")
    func createSupportsNestedCategories() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let repo = CategoryRepository(container: vault.container)

        let parent = try repo.create(name: "Work Travel", type: "expense")
        let child = try repo.create(name: "Travel and Meals", type: "expense", parentId: parent.id)
        let grandchild = try repo.create(name: "Airfare", type: "expense", parentId: child.id)

        #expect(child.parentId == parent.id)
        #expect(child.fullName == "Work Travel:Travel and Meals")
        #expect(grandchild.parentId == child.id)
        #expect(grandchild.fullName == "Work Travel:Travel and Meals:Airfare")
        #expect(try repo.findByPath("Work Travel:Travel and Meals:Airfare")?.id == grandchild.id)

        let tree = try repo.getTree(type: "expense")
        let root = try #require(tree.first { $0.id == parent.id })
        let nestedChild = try #require(root.children.first { $0.id == child.id })
        #expect(nestedChild.children.contains { $0.id == grandchild.id })
        #expect(try repo.auditCategoryEntities().isEmpty)
    }

    @Test("create rejects invalid type and non-category parent")
    func createValidatesInput() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let repo = CategoryRepository(container: vault.container)

        #expect(throws: ToolError.self) {
            _ = try repo.create(name: "Bad Type", type: "asset")
        }

        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: usd)
        let accountId = BaseRepository.extractPK(from: account.objectID)

        #expect(throws: ToolError.self) {
            _ = try repo.create(name: "Bad Child", type: "expense", parentId: accountId)
        }
    }

    @Test("audit detects income and expense rows stored as PrimaryAccount")
    func auditFindsMalformedCategoryEntities() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let ctx = vault.container.viewContext
        let malformed = NSEntityDescription.insertNewObject(forEntityName: "PrimaryAccount", into: ctx)
        malformed.setValue("Malformed Dividend Income", forKey: "pName")
        malformed.setValue("Investments:Malformed Dividend Income", forKey: "pFullName")
        malformed.setValue(AccountClass.income, forKey: "pAccountClass")
        malformed.setValue(false, forKey: "pHidden")
        malformed.setValue(UUID().uuidString, forKey: "pUniqueID")
        malformed.setValue(Date(), forKey: "pCreationTime")
        malformed.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()

        let repo = CategoryRepository(container: vault.container)
        let audit = try repo.auditCategoryEntities()

        let issue = try #require(audit.first)
        #expect(issue.name == "Malformed Dividend Income")
        #expect(issue.type == "income")
        #expect(issue.actualEntity == "PrimaryAccount")
        #expect(issue.expectedEntity == "Category")
    }

    @Test("a malformed row is reported by the audit and kept out of the category list")
    func malformedRowIsNotListedAsACategory() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let repo = CategoryRepository(container: vault.container)
        _ = try repo.create(name: "Groceries", type: "expense")

        // The shape a vault is left in by the create bug this builds on: an
        // income/expense row stored as PrimaryAccount. `Category` is a subentity
        // of `Account`, so a fetch on "Account" happily returns both, and the
        // corrupt row reads back as an ordinary category.
        let ctx = vault.container.viewContext
        let malformed = NSEntityDescription.insertNewObject(forEntityName: "PrimaryAccount", into: ctx)
        malformed.setValue("Not A Category", forKey: "pName")
        malformed.setValue("Not A Category", forKey: "pFullName")
        malformed.setValue(AccountClass.expense, forKey: "pAccountClass")
        malformed.setValue(false, forKey: "pHidden")
        malformed.setValue(UUID().uuidString, forKey: "pUniqueID")
        malformed.setValue(Date(), forKey: "pCreationTime")
        malformed.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()

        let listed = try repo.list().map(\.name)
        #expect(listed.contains("Groceries"))
        #expect(
            !listed.contains("Not A Category"),
            "a PrimaryAccount row must not read back as a category: \(listed)"
        )

        // It is not ignored, it is reportable -- that is what the audit is for.
        #expect(try repo.auditCategoryEntities().contains { $0.name == "Not A Category" })
    }

    private func fetchCategoryEntityName(id: Int, in container: NSPersistentContainer) throws -> String {
        let repo = BaseRepository(container: container)
        return try repo.performRead { ctx in
            let object = try #require(try repo.fetchByPK(entityName: "Category", pk: id, in: ctx))
            return try #require(object.entity.name)
        }
    }
}
