//
//  ApiRequest.swift
//  ClashX
//
//  Created by CYC on 2018/7/30.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import Alamofire
import Cocoa
import Starscream
import SwiftyJSON

protocol ApiRequestStreamDelegate: AnyObject {
    func didUpdateTraffic(up: Int, down: Int)
    func didGetLog(log: String, level: String)
}

typealias ErrorString = String

class ApiRequest {
    static let shared = ApiRequest()

    private var proxyRespCache: ClashProxyResp?

    private lazy var logQueue = DispatchQueue(label: "com.ClashX.core.log")

    static let clashRequestQueue = DispatchQueue(label: "com.clashx.clashRequestQueue")

    @objc enum ProviderType: Int {
        case rule, proxy

        func apiString() -> String {
            self == .proxy ? "proxies" : "rules"
        }

        func logString() -> String {
            self == .proxy ? "Proxy" : "Rule"
        }
    }

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 604800
        configuration.timeoutIntervalForResource = 604800
        configuration.httpMaximumConnectionsPerHost = 100
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        alamoFireManager = Session(configuration: configuration)
    }

    private static func authHeader() -> HTTPHeaders {
        let secret = ConfigManager.shared.overrideSecret ?? ConfigManager.shared.apiSecret
        return (secret.count > 0) ? ["Authorization": "Bearer \(secret)"] : [:]
    }

    @discardableResult
    private static func req(
        _ url: String,
        method: HTTPMethod = .get,
        parameters: Parameters? = nil,
        encoding: ParameterEncoding = URLEncoding.default
    )
        -> DataRequest {
        guard ConfigManager.shared.isRunning else {
            return AF.request("")
        }

        return shared.alamoFireManager
            .request(ConfigManager.apiUrl + url,
                     method: method,
                     parameters: parameters,
                     encoding: encoding,
                     headers: authHeader())
    }

    weak var delegate: ApiRequestStreamDelegate?

    private var trafficWebSocket: WebSocket?
    private var loggingWebSocket: WebSocket?

    private var trafficWebSocketRetryDelay: TimeInterval = 1
    private var loggingWebSocketRetryDelay: TimeInterval = 1
    private var trafficWebSocketRetryTimer: Timer?
    private var loggingWebSocketRetryTimer: Timer?

    private var alamoFireManager: Session

    static func requestConfig(completeHandler: @escaping ((ClashConfig) -> Void)) {
        req("/configs").responseDecodable(of: ClashConfig.self) {
            resp in
            switch resp.result {
            case let .success(config):
                completeHandler(config)
            case let .failure(err):
                Logger.log(err.localizedDescription)
                NSUserNotificationCenter.default.post(title: "Error", info: err.localizedDescription)
            }
        }
    }

    static func findConfigPath(configName: String, callback: @escaping ((String?) -> Void)) {
        if ICloudManager.shared.useiCloud.value {
            ICloudManager.shared.getUrl { url in
                guard let url = url else {
                    callback(nil)
                    return
                }
                let configPath = url.appendingPathComponent(Paths.configFileName(for: configName)).path
                callback(configPath)
            }
        } else {
            let filePath = Paths.localConfigPath(for: configName)
            callback(filePath)
        }
    }

    static func requestConfigUpdate(configName: String, callback: @escaping ((ErrorString?) -> Void)) {
        findConfigPath(configName: configName) { path in
            guard let path = path else {
                callback("icloud error")
                return
            }
            requestConfigUpdate(configPath: path, callback: callback)
        }
    }

    static func requestConfigUpdate(configPath: String, callback: @escaping ((ErrorString?) -> Void)) {
        let placeHolderErrorDesp = "Error occoured, Please try to fix it by restarting ClashX. "

        req("/configs", method: .put, parameters: ["Path": configPath], encoding: JSONEncoding.default).responseJSON { res in
            if res.response?.statusCode == 204 {
                ConfigManager.shared.isRunning = true
                callback(nil)
            } else {
                let errorJson = try? res.result.get()
                let err = JSON(errorJson ?? "")["message"].string ?? placeHolderErrorDesp
                Logger.log(err)
                callback(err)
            }
        }
    }

    static func updateOutBoundMode(mode: ClashProxyMode, callback: ((Bool) -> Void)? = nil) {
        req("/configs", method: .patch, parameters: ["mode": mode.rawValue], encoding: JSONEncoding.default)
            .responseData { response in
                switch response.result {
                case .success:
                    callback?(true)
                case .failure:
                    callback?(false)
                }
            }
    }

    static func updateLogLevel(level: ClashLogLevel, callback: ((Bool) -> Void)? = nil) {
        req("/configs", method: .patch, parameters: ["log-level": level.rawValue], encoding: JSONEncoding.default).responseData(completionHandler: { response in
            switch response.result {
            case .success:
                callback?(true)
            case .failure:
                callback?(false)
            }
        })
    }

    static func requestProxyGroupList(completeHandler: ((ClashProxyResp) -> Void)? = nil) {
        req("/proxies").responseData {
            res in
            let proxies = ClashProxyResp(try? res.result.get())
            ApiRequest.shared.proxyRespCache = proxies
            completeHandler?(proxies)
        }
    }

    static func requestProxyProviderList(completeHandler: ((ClashProviderResp) -> Void)? = nil) {
        req("/providers/proxies")
            .responseDecodable(of: ClashProviderResp.self, decoder: ClashProviderResp.decoder) { resp in
                switch resp.result {
                case let .success(providerResp):
                    completeHandler?(providerResp)
                case let .failure(err):
                    Logger.log("requestProxyProviderList error \(err.localizedDescription)")
                    completeHandler?(ClashProviderResp())
                }
            }
    }

    static func updateAllowLan(allow: Bool, completeHandler: (() -> Void)? = nil) {
        Logger.log("update allow lan:\(allow)", level: .debug)
        req("/configs",
            method: .patch,
            parameters: ["allow-lan": allow],
            encoding: JSONEncoding.default).response {
            _ in
            completeHandler?()
        }
    }

    static func updateProxyGroup(group: String, selectProxy: String, callback: @escaping ((Bool) -> Void)) {
        req("/proxies/\(group.encoded)",
            method: .put,
            parameters: ["name": selectProxy],
            encoding: JSONEncoding.default)
            .responseData { response in
                callback(response.response?.statusCode == 204)
            }
    }

    static func getAllProxyList(callback: @escaping (([ClashProxyName]) -> Void)) {
        requestProxyGroupList {
            proxyInfo in
            let lists: [ClashProxyName] = proxyInfo.proxiesMap["GLOBAL"]?.all ?? []
            callback(lists)
        }
    }

    static func getMergedProxyData(complete: ((ClashProxyResp?) -> Void)? = nil) {
        let group = DispatchGroup()
        group.enter()
        group.enter()

        var provider: ClashProviderResp?
        var proxyInfo: ClashProxyResp?

        group.notify(queue: .main) {
            guard let proxyInfo = proxyInfo, let proxyprovider = provider else {
                assertionFailure()
                complete?(nil)
                return
            }
            proxyInfo.updateProvider(proxyprovider)
            complete?(proxyInfo)
        }

        ApiRequest.requestProxyProviderList {
            proxyprovider in
            provider = proxyprovider
            group.leave()
        }

        ApiRequest.requestProxyGroupList {
            proxy in
            proxyInfo = proxy
            group.leave()
        }
    }

    static func getProxyDelay(proxyName: String, callback: @escaping ((Int) -> Void)) {
        req("/proxies/\(proxyName.encoded)/delay",
            method: .get,
            parameters: ["timeout": 2500, "url": ConfigManager.shared.benchMarkUrl])
            .responseData { res in
                switch res.result {
                case let .success(value):
                    let json = JSON(value)
                    callback(json["delay"].intValue)
                case .failure:
                    callback(0)
                }
            }
    }

    static func getGroupDelay(groupName: String, callback: @escaping (([String: Int]) -> Void)) {
        req("/group/\(groupName.encoded)/delay",
            method: .get,
            parameters: ["timeout": 2500, "url": ConfigManager.shared.benchMarkUrl])
            .responseData { res in
                switch res.result {
                case let .success(value):
                    let dic = try? JSONDecoder().decode([String: Int].self, from: value)
                    callback(dic ?? [:])
                case .failure:
                    callback([:])
                }
            }
    }

    static func getRules(completeHandler: @escaping ([ClashRule]) -> Void) {
        req("/rules").responseData { res in
            guard let data = try? res.result.get() else { return }

            ClashRuleProviderResp.init()

            let rule = ClashRuleResponse.fromData(data)
            completeHandler(rule.rules ?? [])
        }
    }

    static func healthCheck(proxy: ClashProviderName, completeHandler: (() -> Void)? = nil) {
        Logger.log("HeathCheck for \(proxy) started")
        req("/providers/proxies/\(proxy.encoded)/healthcheck").response { res in
            if res.response?.statusCode == 204 {
                Logger.log("HeathCheck for \(proxy) finished")
            } else {
                Logger.log("HeathCheck for \(proxy) failed:\(res.response?.statusCode ?? -1)")
            }
            completeHandler?()
        }
    }
}

// MARK: - Connections

extension ApiRequest {
    static func getConnections(completeHandler: @escaping ([ClashConnectionSnapShot.Connection]) -> Void) {
        req("/connections").responseDecodable(of: ClashConnectionSnapShot.self) { resp in
            switch resp.result {
            case let .success(snapshot):
                completeHandler(snapshot.connections)
            case .failure:
                assertionFailure()
                completeHandler([])
            }
        }
    }

    static func closeConnection(_ conn: ClashConnectionSnapShot.Connection) {
        req("/connections/".appending(conn.id), method: .delete).response { _ in }
    }

    static func closeAllConnection() {
        req("/connections", method: .delete).response { _ in }
    }
}

// MARK: - Meta

extension ApiRequest {
    static func updateAllProviders(for type: ProviderType, completeHandler: ((Int) -> Void)? = nil) {
        var failuresCount = 0

        let group = DispatchGroup()
        group.enter()

        if type == .proxy {
            requestProxyProviderList { resp in
                resp.allProviders.filter {
                    $0.value.vehicleType == .HTTP
                }.forEach {
                    group.enter()
                    updateProvider(for: .proxy, name: $0.key) {
                        if !$0 {
                            failuresCount += 1
                        }
                        group.leave()
                    }
                }
                group.leave()
            }
        } else {
            requestRuleProviderList { resp in
                resp.allProviders.forEach {
                    group.enter()
                    updateProvider(for: .rule, name: $0.key) {
                        if !$0 {
                            failuresCount += 1
                        }
                        group.leave()
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completeHandler?(failuresCount)
        }
    }

    static func updateProvider(for type: ProviderType, name: String, completeHandler: ((Bool) -> Void)? = nil) {
        let s = "Update \(type.logString()) Provider"

        Logger.log("\(s) \(name)")
        req("/providers/\(type.apiString())/\(name)", method: .put).response {
            let re = $0.response?.statusCode == 204
            Logger.log("\(s) \(name) \(re ? "success" : "failed")")
            completeHandler?(re)
        }
    }

    static func requestRuleProviderList(completeHandler: @escaping (ClashRuleProviderResp) -> Void) {
        req("/providers/rules")
            .responseDecodable(of: ClashRuleProviderResp.self, decoder: ClashProviderResp.decoder) { resp in
            switch resp.result {
            case let .success(providerResp):
                completeHandler(providerResp)
            case let .failure(err):
                Logger.log("Get Rule providers error \(err.errorDescription ?? "unknown")" )
                completeHandler(ClashRuleProviderResp())
            }
        }
    }

    static func updateGEO(completeHandler: ((Bool) -> Void)? = nil) {
        Logger.log("UpdateGEO")
        req("/configs/geo", method: .post).response {
            let re = $0.response?.statusCode == 204

            completeHandler?(re)
//            Logger.log("UpdateGEO \(re ? "success" : "failed")")
            Logger.log("Updating GEO Databases...")
        }
    }

    static func updateTun(enable: Bool, completeHandler: (() -> Void)? = nil) {
        Logger.log("update tun:\(enable)", level: .debug)
        req("/configs",
            method: .patch,
            parameters: ["tun": ["enable": enable]],
            encoding: JSONEncoding.default).response {
            _ in
            completeHandler?()
        }
    }

    static func updateSniffing(enable: Bool, completeHandler: (() -> Void)? = nil) {
        Logger.log("update sniffing:\(enable)", level: .debug)
        req("/configs",
            method: .patch,
            parameters: ["sniffing": enable],
            encoding: JSONEncoding.default).response {
            _ in
            completeHandler?()
        }
    }

    static func flushFakeipCache(completeHandler: ((Bool) -> Void)? = nil) {
        Logger.log("FlushFakeipCache")
        req("/cache/fakeip/flush",
            method: .post).response {
            let re = $0.response?.statusCode == 204
            completeHandler?(re)
            Logger.log("FlushFakeipCache \(re ? "success" : "failed")")
        }
    }
}

// MARK: - Stream Apis

extension ApiRequest {
    func resetStreamApis() {
        resetLogStreamApi()
        resetTrafficStreamApi()
    }

    func resetLogStreamApi() {
        loggingWebSocketRetryTimer?.invalidate()
        loggingWebSocketRetryTimer = nil
        loggingWebSocketRetryDelay = 1
        requestLog()
    }

    func resetTrafficStreamApi() {
        trafficWebSocketRetryTimer?.invalidate()
        trafficWebSocketRetryTimer = nil
        trafficWebSocketRetryDelay = 1
        requestTrafficInfo()
    }

    private func requestTrafficInfo() {
        trafficWebSocketRetryTimer?.invalidate()
        trafficWebSocketRetryTimer = nil
        trafficWebSocket?.disconnect(forceTimeout: 0.5)

        let socket = WebSocket(url: URL(string: ConfigManager.apiUrl.appending("/traffic"))!)

        for header in ApiRequest.authHeader() {
            socket.request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        socket.delegate = self
        socket.connect()
        trafficWebSocket = socket
    }

    private func requestLog() {
        loggingWebSocketRetryTimer?.invalidate()
        loggingWebSocketRetryTimer = nil
        loggingWebSocket?.disconnect(forceTimeout: 1)

        let uriString = "/logs?level=".appending(ConfigManager.selectLoggingApiLevel.rawValue)
        let socket = WebSocket(url: URL(string: ConfigManager.apiUrl.appending(uriString))!)
        for header in ApiRequest.authHeader() {
            socket.request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        socket.delegate = self
        socket.callbackQueue = logQueue
        socket.connect()
        loggingWebSocket = socket
    }
}

extension ApiRequest: WebSocketDelegate {
    func websocketDidConnect(socket: WebSocketClient) {
        guard let webSocket = socket as? WebSocket else { return }
        if webSocket == trafficWebSocket {
            trafficWebSocketRetryDelay = 1
            Logger.log("trafficWebSocket did Connect", level: .debug)
        } else {
            loggingWebSocketRetryDelay = 1
            Logger.log("loggingWebSocket did Connect", level: .debug)
        }
    }

    func websocketDidDisconnect(socket: WebSocketClient, error: Error?) {
        guard let err = error else {
            return
        }

        Logger.log(err.localizedDescription, level: .error)

        guard let webSocket = socket as? WebSocket else { return }

        if webSocket == trafficWebSocket {
            Logger.log("trafficWebSocket did disconnect", level: .debug)
            trafficWebSocketRetryTimer?.invalidate()
            trafficWebSocketRetryTimer =
                Timer.scheduledTimer(withTimeInterval: trafficWebSocketRetryDelay, repeats: false, block: {
                    [weak self] _ in
                    if self?.trafficWebSocket?.isConnected == true { return }
                    self?.requestTrafficInfo()
                })
            trafficWebSocketRetryDelay *= 2
        } else {
            Logger.log("loggingWebSocket did disconnect", level: .debug)
            loggingWebSocketRetryTimer =
                Timer.scheduledTimer(withTimeInterval: loggingWebSocketRetryDelay, repeats: false, block: {
                    [weak self] _ in
                    if self?.loggingWebSocket?.isConnected == true { return }
                    self?.requestLog()
                })
            loggingWebSocketRetryDelay *= 2
        }
    }

    func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
        guard let webSocket = socket as? WebSocket else { return }
        let json = JSON(parseJSON: text)
        if webSocket == trafficWebSocket {
            delegate?.didUpdateTraffic(up: json["up"].intValue, down: json["down"].intValue)
        } else {
            delegate?.didGetLog(log: json["payload"].stringValue, level: json["type"].string ?? "info")
        }
    }

    func websocketDidReceiveData(socket: WebSocketClient, data: Data) {}
}
