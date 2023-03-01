//
//  QRCodeResolutionCoordinator.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 10.09.2020.
//

import Foundation
import BigInt
import PromiseKit
import AlphaWalletFoundation
import AlphaWalletLogger
import Combine

enum QrCodeResolution {
    case address(address: AlphaWallet.Address, action: ScanQRCodeAction)
    case transactionType(transactionType: TransactionType, token: Token)
    case walletConnectUrl(url: AlphaWallet.WalletConnect.ConnectionUrl)
    case string(value: String)
    case url(url: URL)
    case json(json: String)
    case seedPhase(seedPhase: [String])
    case privateKey(privateKey: String)
}

protocol QRCodeResolutionCoordinatorDelegate: AnyObject {
    func coordinator(_ coordinator: QRCodeResolutionCoordinator, didResolve qrCodeResolution: QrCodeResolution)
    func didCancel(in coordinator: QRCodeResolutionCoordinator)
}

final class QRCodeResolutionCoordinator: Coordinator {
    enum Usage {
        case all(tokensService: TokenProvidable, sessionsProvider: SessionsProvider)
        case importWalletOnly
    }

    private let config: Config
    private let usage: Usage
    private var skipResolvedCodes: Bool = false
    private var navigationController: UINavigationController {
        scanQRCodeCoordinator.parentNavigationController
    }
    private let scanQRCodeCoordinator: ScanQRCodeCoordinator
    private let account: Wallet
    private var cancellable = Set<AnyCancellable>()

    var coordinators: [Coordinator] = []
    weak var delegate: QRCodeResolutionCoordinatorDelegate?

    init(config: Config, coordinator: ScanQRCodeCoordinator, usage: Usage, account: Wallet) {
        self.config = config
        self.usage = usage
        self.scanQRCodeCoordinator = coordinator
        self.account = account
    }

    func start(fromSource source: Analytics.ScanQRCodeSource, clipboardString: String? = nil) {
        scanQRCodeCoordinator.delegate = self
        addCoordinator(scanQRCodeCoordinator)

        scanQRCodeCoordinator.start(fromSource: source, clipboardString: clipboardString)
    }
}

extension QRCodeResolutionCoordinator: ScanQRCodeCoordinatorDelegate {

    func didCancel(in coordinator: ScanQRCodeCoordinator) {
        delegate?.didCancel(in: self)
    }

    func didScan(result: String, in coordinator: ScanQRCodeCoordinator) {
        guard !skipResolvedCodes else { return }

        skipResolvedCodes = true
        resolveScanResult(result)
    }

    private func availableActions(forContract contract: AlphaWallet.Address) -> [ScanQRCodeAction] {
        switch usage {
        case .all(let tokensService, _):
            let isTokenFound = tokensService.token(for: contract, server: .main) != nil
            if isTokenFound {
                return [.sendToAddress, .watchWallet, .openInEtherscan]
            } else {
                return [.sendToAddress, .addCustomToken, .watchWallet, .openInEtherscan]
            }
        case .importWalletOnly:
            return [.watchWallet]
        }
    }

    private func resolveScanResult(_ string: String) {
        guard let delegate = delegate else { return }
        let qrCodeValue = QrCodeValue(string: string)
        infoLog("[QR Code] resolved: \(qrCodeValue)")

        switch qrCodeValue {
        case .addressOrEip681(let value):
            switch value {
            case .address(let contract):
                let actions = availableActions(forContract: contract)
                if actions.count == 1 {
                    delegate.coordinator(self, didResolve: .address(address: contract, action: actions[0]))
                } else {
                    showDidScanWalletAddress(for: actions, completion: { action in
                        delegate.coordinator(self, didResolve: .address(address: contract, action: action))
                    }, cancelCompletion: {
                        self.skipResolvedCodes = false
                    })
                }
            case .eip681(let protocolName, let address, let functionName, let params):
                switch usage {
                case .all(_, let sessionsProvider):
                    let resolver = Eip681UrlResolver(
                        config: config,
                        sessionsProvider: sessionsProvider,
                        missingRPCServerStrategy: .fallbackToFirstMatching)

                    resolver.resolve(protocolName: protocolName, address: address, functionName: functionName, params: params)
                        .sink(receiveCompletion: { result in
                            guard case .failure(let error) = result else { return }
                            verboseLog("[Eip681UrlResolver] failure to resolve value from: \(qrCodeValue) with error: \(error)")
                        }, receiveValue: { result in
                            switch result {
                            case .transaction(let transactionType, let token):
                                delegate.coordinator(self, didResolve: .transactionType(transactionType: transactionType, token: token))
                            case .address:
                                break // Not possible here
                            }
                        }).store(in: &cancellable)
                case .importWalletOnly:
                    break
                }
            }
        case .string(let value):
            delegate.coordinator(self, didResolve: .string(value: value))
        case .walletConnect(let url):
            delegate.coordinator(self, didResolve: .walletConnectUrl(url: url))
        case .url(let url):
            showOpenURL(completion: {
                delegate.coordinator(self, didResolve: .url(url: url))
            }, cancelCompletion: {
                //NOTE: we need to reset flag to false to make sure that next detected QR code will be handled
                self.skipResolvedCodes = false
            })
        case .json(let value):
            delegate.coordinator(self, didResolve: .json(json: value))
        case .privateKey(let value):
            delegate.coordinator(self, didResolve: .privateKey(privateKey: value))
        case .seedPhase(let value):
            delegate.coordinator(self, didResolve: .seedPhase(seedPhase: value))
        }
    }

    private func showDidScanWalletAddress(for actions: [ScanQRCodeAction], completion: @escaping (ScanQRCodeAction) -> Void, cancelCompletion: @escaping () -> Void) {
        let preferredStyle: UIAlertController.Style = UIDevice.current.userInterfaceIdiom == .pad ? .alert : .actionSheet
        let controller = UIAlertController(title: nil, message: nil, preferredStyle: preferredStyle)

        for action in actions {
            let alertAction = UIAlertAction(title: action.title, style: .default) { _ in
                completion(action)
            }

            controller.addAction(alertAction)
        }

        let cancelAction = UIAlertAction(title: R.string.localizable.cancel(), style: .cancel) { _ in
            cancelCompletion()
        }

        controller.addAction(cancelAction)

        navigationController.present(controller, animated: true)
    }

    private func showOpenURL(completion: @escaping () -> Void, cancelCompletion: @escaping () -> Void) {
        let preferredStyle: UIAlertController.Style = UIDevice.current.userInterfaceIdiom == .pad ? .alert : .actionSheet
        let controller = UIAlertController(title: nil, message: nil, preferredStyle: preferredStyle)

        let alertAction = UIAlertAction(title: R.string.localizable.qrCodeOpenInBrowserTitle(), style: .default) { _ in
            completion()
        }

        let cancelAction = UIAlertAction(title: R.string.localizable.cancel(), style: .cancel) { _ in
            cancelCompletion()
        }

        controller.addAction(alertAction)
        controller.addAction(cancelAction)

        navigationController.present(controller, animated: true)
    }
}

extension ScanQRCodeAction {
    var title: String {
        switch self {
        case .sendToAddress:
            return R.string.localizable.qrCodeSendToAddressTitle()
        case .addCustomToken:
            return R.string.localizable.qrCodeAddCustomTokenTitle()
        case .watchWallet:
            return R.string.localizable.qrCodeWatchWalletTitle()
        case .openInEtherscan:
            return R.string.localizable.qrCodeOpenInEtherscanTitle()
        }
    }
}
