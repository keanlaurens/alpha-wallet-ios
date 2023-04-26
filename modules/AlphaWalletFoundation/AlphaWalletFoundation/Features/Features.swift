// Copyright © 2020 Stormbird PTE. LTD.

import Foundation
import AlphaWalletLogger

public class Features {
    public static let `default`: Features = Features()!

    private let encoder: JSONEncoder = JSONEncoder()
    private let fileUrl: URL

    private var isMutationAvailable: Bool {
        return (Environment.isTestFlight || Environment.isDebug)
    }
    private var featuresDictionary: AtomicDictionary<FeaturesAvailable, Bool> = .init()

    public init?(fileName: String = "Features.json") {
        do {
            var url: URL = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            url.appendPathComponent(fileName)
            self.fileUrl = url
            self.readFromFileUrl()
        } catch {
            verboseLog("[Features] init Exception: \(error)")
            return nil
        }
    }

    private func readFromFileUrl() {
        do {
            let decoder = JSONDecoder()
            let data = try Data(contentsOf: fileUrl)
            let jsonData = try decoder.decode([FeaturesAvailable: Bool].self, from: data)
            featuresDictionary.set(value: jsonData)
        } catch {
            verboseLog("[Features] readFromFileUrl error: \(error)")
            featuresDictionary.set(value: [:])
        }
    }

    private func writeToFileUrl() {
        do {
            let data = try encoder.encode(featuresDictionary.values)
            if let jsonString = String(data: data, encoding: .utf8) {
                try jsonString.write(to: fileUrl, atomically: true, encoding: .utf8)
            }
        } catch {
            verboseLog("[Features] writeToFileUrl error: \(error)")
        }
    }

    public func isAvailable(_ item: FeaturesAvailable) -> Bool {
        if isMutationAvailable, let value = featuresDictionary[item] {
            return value
        }
        return item.defaultValue
    }

    public func setAvailable(_ item: FeaturesAvailable, _ value: Bool) {
        guard isMutationAvailable else { return }
        featuresDictionary[item] = value
        writeToFileUrl()
    }

    public func invert(_ item: FeaturesAvailable) {
        let value = !isAvailable(item)
        setAvailable(item, value)
    }

    public func reset() {
        FeaturesAvailable.allCases.forEach { key in
            setAvailable(key, key.defaultValue)
        }
    }

}

public enum FeaturesAvailable: String, CaseIterable, Codable {
    case isActivityEnabled
    case isSpeedupAndCancelEnabled
    case isLanguageSwitcherEnabled
    case shouldLoadTokenScriptWithFailedSignatures
    case isRenameWalletEnabledWhileLongPress
    case shouldPrintCURLForOutgoingRequest
    case isPromptForEmailListSubscriptionEnabled
    case isAlertsEnabled
    case isUsingPrivateNetwork
    case isUsingAppEnforcedTimeoutForMakingWalletConnectConnections
    case isAttachingLogFilesToSupportEmailEnabled
    case isExportJsonKeystoreEnabled
    case is24SeedWordPhraseAllowed
    case isAnalyticsUIEnabled
    case isBlockscanChatEnabled
    case isTokenScriptSignatureStatusEnabled
    case isSwapEnabled
    case isCoinbasePayEnabled
    case isLoggingEnabledForTickerMatches
    case isChangeCurrencyEnabled
    case isNftTransferEnabled
    case isEip1559Enabled

    public var defaultValue: Bool {
        switch self {
        case .isActivityEnabled: return true
        case .isSpeedupAndCancelEnabled: return true
        case .isLanguageSwitcherEnabled: return false
        case .shouldLoadTokenScriptWithFailedSignatures: return true
        case .isRenameWalletEnabledWhileLongPress: return true
        case .shouldPrintCURLForOutgoingRequest: return false
        case .isPromptForEmailListSubscriptionEnabled: return true
        case .isAlertsEnabled: return false
        case .isUsingPrivateNetwork: return true
        case .isUsingAppEnforcedTimeoutForMakingWalletConnectConnections: return true
        case .isAttachingLogFilesToSupportEmailEnabled: return false
        case .isExportJsonKeystoreEnabled: return true
        case .is24SeedWordPhraseAllowed: return true
        case .isAnalyticsUIEnabled: return true
        case .isBlockscanChatEnabled: return true
        case .isTokenScriptSignatureStatusEnabled: return false
        case .isSwapEnabled: return true
        case .isCoinbasePayEnabled: return true
        case .isLoggingEnabledForTickerMatches: return false
        case .isChangeCurrencyEnabled: return false
        case .isNftTransferEnabled: return false
        case .isEip1559Enabled: return false
        }
    }

    public var descriptionLabel: String {
        return self.rawValue.insertSpaceBeforeCapitals()
    }
}
