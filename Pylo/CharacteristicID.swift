// MARK: - Characteristic ID (for event subscriptions)

nonisolated struct CharacteristicID: Hashable, Sendable {
  let aid: Int
  let iid: Int
}
