// Copyright SIX DAY LLC. All rights reserved.

import Foundation
import JSONRPCKit
import AlphaWalletLogger

struct GetTransactionRequest: JSONRPCKit.Request {
    typealias Response = EthereumTransaction?

    let hash: String

    var method: String {
        return "eth_getTransactionByHash"
    }

    var parameters: Any? {
        return [hash]
    }

    func response(from resultObject: Any) throws -> Response {
        if resultObject is NSNull {
            infoLog("[RPC] Fetch transaction by hash: \(hash) is null")
            return nil
        }
        guard let dict = resultObject as? [String: AnyObject] else {
            throw CastError(actualValue: resultObject, expectedType: Response.self)
        }
        return EthereumTransaction(dict)
    }
}
