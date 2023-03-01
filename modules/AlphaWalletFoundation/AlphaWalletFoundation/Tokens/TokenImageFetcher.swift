// Copyright © 2020 Stormbird PTE. LTD.

import UIKit
import PromiseKit
import AlphaWalletCore
import AlphaWalletLogger
import AlphaWalletOpenSea
import Combine

public typealias GoogleContentSize = AlphaWalletCore.GoogleContentSize
public typealias WebImageURL = AlphaWalletCore.WebImageURL
public typealias Image = UIImage
public typealias TokenImagePublisher = AnyPublisher<TokenImage?, Never>

public struct TokenImage {
    public let image: ImageOrWebImageUrl
    public let isFinal: Bool
    public let overlayServerIcon: UIImage?

    public init(image: ImageOrWebImageUrl, isFinal: Bool, overlayServerIcon: UIImage?) {
        self.image = image
        self.isFinal = isFinal
        self.overlayServerIcon = overlayServerIcon
    }
}

public protocol ImageFetcher: AnyObject {
    func retrieveImage(with url: URL) -> Promise<UIImage>
}

public protocol HasTokenImage {
    var name: String { get }
    var symbol: String { get }
    var contractAddress: AlphaWallet.Address { get }
    var type: TokenType { get }
    var server: RPCServer { get }
    var firstNftAsset: NonFungibleFromJson? { get }
}

extension Token: HasTokenImage {
    public var firstNftAsset: NonFungibleFromJson? {
        balance.compactMap { $0.nonFungibleBalance }.first
    }
}

extension TokenViewModel: HasTokenImage {
    public var firstNftAsset: NonFungibleFromJson? {
        balance.balance.compactMap { $0.nonFungibleBalance }.first
    }
}

extension PopularToken: HasTokenImage {
    public var symbol: String { "" }
    public var type: TokenType { .erc20 }
    public var firstNftAsset: NonFungibleFromJson? { nil }
}

public protocol TokenImageFetcher {
    func image(contractAddress: AlphaWallet.Address,
               server: RPCServer,
               name: String,
               type: TokenType,
               balance: NonFungibleFromJson?,
               size: GoogleContentSize,
               contractDefinedImage: UIImage?,
               colors: [UIColor],
               staticOverlayIcon: UIImage?,
               blockChainNameColor: UIColor,
               serverIconImage: UIImage?) -> TokenImagePublisher
}

public class TokenImageFetcherImpl: TokenImageFetcher {
    private let networking: ImageFetcher
    private let subscribables: AtomicDictionary<String, CurrentValueSubject<TokenImage?, Never>> = .init()

    enum ImageAvailabilityError: LocalizedError {
        case notAvailable
    }

    public init(networking: ImageFetcher) {
        self.networking = networking
    }

    private static func programmaticallyGenerateIcon(for contractAddress: AlphaWallet.Address,
                                                     type: TokenType,
                                                     server: RPCServer,
                                                     symbol: String,
                                                     colors: [UIColor],
                                                     staticOverlayIcon: UIImage?,
                                                     blockChainNameColor: UIColor) -> TokenImage? {

        guard let i = [Constants.Image.numberOfCharactersOfSymbolToShowInIcon, symbol.count].min() else { return nil }
        let symbol = symbol.substring(to: i)
        let rawImage: UIImage?
        let overlayServerIcon: UIImage?

        switch type {
        case .erc1155, .erc721, .erc721ForTickets:
            rawImage = nil
            overlayServerIcon = staticOverlayIcon
        case .erc20, .erc875:
            rawImage = programmaticallyGeneratedIconImage(
                for: contractAddress,
                server: server,
                colors: colors,
                blockChainNameColor: blockChainNameColor)

            overlayServerIcon = staticOverlayIcon
        case .nativeCryptocurrency:
            rawImage = programmaticallyGeneratedIconImage(
                for: contractAddress,
                server: server,
                colors: colors,
                blockChainNameColor: blockChainNameColor)

            overlayServerIcon = nil
        }
        let imageSource = rawImage.flatMap { RawImage.generated(image: $0, symbol: symbol) } ?? .none

        return .init(image: .image(imageSource), isFinal: false, overlayServerIcon: overlayServerIcon)
    }

    private func getDefaultOrGenerateIcon(server: RPCServer,
                                          contractAddress: AlphaWallet.Address,
                                          type: TokenType,
                                          name: String,
                                          tokenImage: UIImage?,
                                          colors: [UIColor],
                                          staticOverlayIcon: UIImage?,
                                          blockChainNameColor: UIColor,
                                          serverIconImage: UIImage?) -> TokenImage? {

        switch type {
        case .nativeCryptocurrency:
            if let img = serverIconImage {
                return .init(image: .image(.loaded(image: img)), isFinal: true, overlayServerIcon: nil)
            }
        case .erc20, .erc875, .erc721, .erc721ForTickets, .erc1155:
            if let img = tokenImage {
                return .init(image: .image(.loaded(image: img)), isFinal: true, overlayServerIcon: staticOverlayIcon)
            }
        }

        return TokenImageFetcherImpl.programmaticallyGenerateIcon(
            for: contractAddress,
            type: type,
            server: server,
            symbol: name,
            colors: colors,
            staticOverlayIcon: staticOverlayIcon,
            blockChainNameColor: blockChainNameColor)
    }

    public func image(contractAddress: AlphaWallet.Address,
                      server: RPCServer,
                      name: String,
                      type: TokenType,
                      balance: NonFungibleFromJson?,
                      size: GoogleContentSize,
                      contractDefinedImage: UIImage?,
                      colors: [UIColor],
                      staticOverlayIcon: UIImage?,
                      blockChainNameColor: UIColor,
                      serverIconImage: UIImage?) -> TokenImagePublisher {
        
        let subject: CurrentValueSubject<TokenImage?, Never>
        let key = "\(contractAddress.eip55String)-\(server.chainID)-\(size.rawValue)"
        if let sub = subscribables[key] {
            subject = sub
            if let value = sub.value, value.isFinal {
                return subject.eraseToAnyPublisher()
            }
        } else {
            let sub = CurrentValueSubject<TokenImage?, Never>(nil)
            subscribables[key] = sub
            subject = sub
        }

        let generatedImage = getDefaultOrGenerateIcon(
            server: server,
            contractAddress: contractAddress,
            type: type,
            name: name,
            tokenImage: contractDefinedImage,
            colors: colors,
            staticOverlayIcon: staticOverlayIcon,
            blockChainNameColor: blockChainNameColor,
            serverIconImage: serverIconImage)

        if contractAddress == Constants.nativeCryptoAddressInDatabase {
            subject.send(generatedImage)
            return subject.eraseToAnyPublisher()
        }

        if subject.value == nil {
            subject.send(generatedImage)
        }

        if let image = generatedImage, image.isFinal {
            return subject.eraseToAnyPublisher()
        }

        firstly {
            self.fetchFromAssetGitHubRepo(.alphaWallet, contractAddress: contractAddress)
                .map { image -> TokenImage in
                    return .init(image: .image(.loaded(image: image)), isFinal: true, overlayServerIcon: staticOverlayIcon)
                }
        }.recover { _ -> Promise<TokenImage> in
            let url = try TokenImageFetcherImpl.nftCollectionImageUrl(type, balance: balance, size: size)
            return .value(.init(image: url, isFinal: true, overlayServerIcon: staticOverlayIcon))
        }.recover { _ -> Promise<TokenImage> in
            return self.fetchFromAssetGitHubRepo(.thirdParty, contractAddress: contractAddress)
                .map { image -> TokenImage in
                    return .init(image: .image(.loaded(image: image)), isFinal: false, overlayServerIcon: staticOverlayIcon)
                }
        }.done { value in
            subject.send(value)
        }.catch { _ in
            subject.send(generatedImage)
        }

        return subject.eraseToAnyPublisher()
    }

    //TODO: refactor and rename
    private static func nftCollectionImageUrl(_ type: TokenType,
                                              balance: NonFungibleFromJson?,
                                              size: GoogleContentSize) throws -> ImageOrWebImageUrl {

        switch type {
        case .erc721, .erc1155:
            guard let openSeaNonFungible = balance, let url = openSeaNonFungible.nftCollectionImageUrl(rewriteGoogleContentSizeUrl: size) else {
                throw ImageAvailabilityError.notAvailable
            }
            return .url(url)
        case .nativeCryptocurrency, .erc20, .erc875, .erc721ForTickets:
            throw ImageAvailabilityError.notAvailable
        }
    }

    //TODO: refactor
    private func fetchFromAssetGitHubRepo(_ githubAssetsSource: GithubAssetsURLResolver.Source,
                                          contractAddress: AlphaWallet.Address) -> Promise<UIImage> {

        struct AnyError: Error { }
        let urlString = githubAssetsSource.url(forContract: contractAddress)
        guard let url = URL(string: urlString) else {
            verboseLog("Loading token icon URL: \(urlString) error")
            return .init(error: AnyError())
        }

        return networking.retrieveImage(with: url)
    }
}

class GithubAssetsURLResolver {
    static let file = "logo.png"

    enum Source: String {
        case alphaWallet = "https://raw.githubusercontent.com/AlphaWallet/iconassets/master/"
        case thirdParty = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/"

        func url(forContract contract: AlphaWallet.Address) -> String {
            switch self {
            case .alphaWallet:
                return rawValue + contract.eip55String.lowercased() + "/" + GithubAssetsURLResolver.file
            case .thirdParty:
                return rawValue + contract.eip55String + "/" + GithubAssetsURLResolver.file
            }
        }
    }
}

public typealias ImagePublisher = AnyPublisher<Image?, Never>

public class RPCServerImageFetcher {
    public static var instance = RPCServerImageFetcher()
    private let subscribables: AtomicDictionary<Int, ImagePublisher> = .init()

    public func image(server: RPCServer, iconImage: UIImage) -> ImagePublisher {
        if let sub = subscribables[server.chainID] {
            return sub
        } else {
            let sub = CurrentValueSubject<Image?, Never>(iconImage)
            subscribables[server.chainID] = sub.eraseToAnyPublisher()

            return sub.eraseToAnyPublisher()
        }
    }
}

private func programmaticallyGeneratedIconImage(for contractAddress: AlphaWallet.Address,
                                                server: RPCServer,
                                                colors: [UIColor],
                                                blockChainNameColor: UIColor) -> UIImage {

    let backgroundColor = symbolBackgroundColor(for: contractAddress, server: server, colors: colors, blockChainNameColor: blockChainNameColor)
    return UIImage.tokenSymbolBackgroundImage(backgroundColor: backgroundColor)
}

private func symbolBackgroundColor(for contractAddress: AlphaWallet.Address,
                                   server: RPCServer,
                                   colors: [UIColor],
                                   blockChainNameColor: UIColor) -> UIColor {

    if contractAddress == Constants.nativeCryptoAddressInDatabase {
        return blockChainNameColor
    } else {
        let index: Int
        //We just need a random number from the contract. The LSBs are more random than the MSBs
        if let i = Int(contractAddress.eip55String.substring(from: 37), radix: 16) {
            index = i % colors.count
        } else {
            index = 0
        }
        return colors[index]
    }
}
