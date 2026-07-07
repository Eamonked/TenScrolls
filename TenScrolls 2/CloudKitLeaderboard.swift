import Foundation
import CloudKit

/// Backs "The Caravan" tab: a public leaderboard, friend lookups by trader code,
/// and a lightweight cheer counter. Uses CKContainer's *public* database so any
/// two people who exchange trader codes can see each other's stats, matching the
/// artifact's `shared: true` storage calls.
///
/// Setup required in the Xcode project (see README):
/// 1. Add the "CloudKit" capability and an iCloud container.
/// 2. In the CloudKit Dashboard, the "Trader" record type needs `xp` marked
///    Queryable + Sortable, and the default `recordName` marked Queryable.
/// 3. The "CheerCount" record type needs its `count` field Queryable.
actor CloudKitLeaderboard {
    private let container: CKContainer
    private let db: CKDatabase

    init() {
        // Replace with your own container identifier, or leave as `.default()`
        // if you only have one iCloud container configured for this app.
        self.container = CKContainer.default()
        self.db = container.publicCloudDatabase
    }

    private func traderRecordID(_ code: String) -> CKRecord.ID { CKRecord.ID(recordName: "trader-\(code)") }
    private func cheerRecordID(_ code: String) -> CKRecord.ID { CKRecord.ID(recordName: "cheer-\(code)") }

    // MARK: - Publish own snapshot

    func publish(code: String, snapshot: FriendSnapshot) async {
        let id = traderRecordID(code)
        do {
            let record: CKRecord
            if let existing = try? await db.record(for: id) {
                record = existing
            } else {
                record = CKRecord(recordType: "Trader", recordID: id)
                record["code"] = code
            }
            record["name"] = snapshot.name
            record["level"] = snapshot.level
            record["xp"] = snapshot.xp
            record["streak"] = snapshot.streak
            record["bestStreak"] = snapshot.bestStreak
            record["totalDays"] = snapshot.totalDays
            record["mastered"] = snapshot.mastered
            record["lastActive"] = snapshot.lastActive
            _ = try await db.save(record)
        } catch {
            // Publish failures are non-fatal — the leaderboard just won't reflect
            // this update until the next successful sync.
        }
    }

    // MARK: - Fetch leaderboard

    func fetchLeaderboard(limit: Int = 50) async throws -> [LeaderboardEntry] {
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: "Trader", predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "xp", ascending: false)]

        let (matchResults, _) = try await db.records(matching: query, resultsLimit: limit)
        return matchResults.compactMap { _, result in
            guard case let .success(record) = result else { return nil }
            return Self.entry(from: record)
        }
    }

    // MARK: - Fetch a single friend by trader code

    func fetchFriend(code: String) async -> FriendSnapshot? {
        guard let record = try? await db.record(for: traderRecordID(code)) else { return nil }
        return Self.entry(from: record)?.snapshot
    }

    // MARK: - Cheers

    func sendCheer(code: String) async {
        let id = cheerRecordID(code)
        do {
            let record: CKRecord
            var count = 0
            if let existing = try? await db.record(for: id) {
                record = existing
                count = (record["count"] as? Int) ?? 0
            } else {
                record = CKRecord(recordType: "CheerCount", recordID: id)
                record["code"] = code
            }
            record["count"] = count + 1
            _ = try await db.save(record)
        } catch {
            // Best-effort — UI already shows an optimistic "sent" state.
        }
    }

    func fetchCheerCount(code: String) async -> Int {
        guard let record = try? await db.record(for: cheerRecordID(code)) else { return 0 }
        return (record["count"] as? Int) ?? 0
    }

    // MARK: - Helpers

    private static func entry(from record: CKRecord) -> LeaderboardEntry? {
        guard
            let code = record["code"] as? String,
            let name = record["name"] as? String
        else { return nil }
        let snapshot = FriendSnapshot(
            name: name,
            level: (record["level"] as? Int) ?? 0,
            xp: (record["xp"] as? Int) ?? 0,
            streak: (record["streak"] as? Int) ?? 0,
            bestStreak: (record["bestStreak"] as? Int) ?? 0,
            totalDays: (record["totalDays"] as? Int) ?? 0,
            mastered: (record["mastered"] as? Int) ?? 0,
            lastActive: (record["lastActive"] as? Date) ?? Date.distantPast
        )
        return LeaderboardEntry(code: code, snapshot: snapshot)
    }
}
