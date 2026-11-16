import Foundation

public enum CloudBackupContribution {
  /// The production index, composed restore workflow and project-page binding are not complete.
  /// Publishing a partial set here would advertise a recovery promise the primitive fixtures do not prove.
  public static let current = CloudFeatureContribution(owner: "BKP", tools: [], inventoryRows: [], actions: [])
}
