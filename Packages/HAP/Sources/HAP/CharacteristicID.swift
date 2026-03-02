// MARK: - Characteristic ID (for event subscriptions)

public nonisolated struct CharacteristicID: Hashable, Sendable {
  public let aid: Int
  public let iid: Int

  public init(aid: Int, iid: Int) {
    self.aid = aid
    self.iid = iid
  }
}
