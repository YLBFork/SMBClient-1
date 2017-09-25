//
//  SMBSession.swift
//  SMBClient
//
//  Created by Seth Faxon on 9/1/17.
//  Copyright © 2017 Filmic. All rights reserved.
//

import libdsm

public class SMBSession {
    internal var smbSession = smb_session_new()
    internal var serialQueue = DispatchQueue(label: "SMBSession")

    lazy var dataQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var lastRequestDate: Date?

    public var hostName: String?
    public var ipAddress: String?
    public var userName: String?
    public var password: String?
    public var sessionGuestState: SessionGuestState?
    public var connected: Bool = false

    public var maxTaskOperationCount = OperationQueue.defaultMaxConcurrentOperationCount

    // tasks
    var downloadTasks: [SessionDownloadTask] = []
    var uploadTasks: [SessionUploadTask] = []
    lazy var taskQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = self.maxTaskOperationCount
        return queue
    }()

    public init() { }

//    public func requestContents(ofShare: SMBVolume)
//    public func requestContents(ofDirectory: SMBDirectory)

    public func requestVolumes() -> Result<[SMBVolume]> {
        let conError = self.attemptConnection()
        // switch result/error
        if let error = conError {
            return Result.failure(error)
        }

        var list: smb_share_list? = smb_share_list.allocate(capacity: 1)

        let shareCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        shareCount.pointee = 0

        smb_share_get_list(self.smbSession, &list, shareCount)

        if shareCount.pointee == 0 {
            return Result.success([])
        }
        var results: [SMBVolume] = []

        var i = 0
        while i <= shareCount.pointee {
            guard let shareNameCString = smb_share_list_at(list!, i) else {
                i += 1
                continue
            }

            var shareName = String(cString: shareNameCString)
            // skip system shares suffixed by '$'
            if shareName.characters.last == "$" {
                i += 1
                continue
            }

            let f = SMBVolume(name: shareName, session: self)
            results.append(f)

            i += 1
        }
        return Result.success(results)
    }

    public func requestVolumes(completionQueue: DispatchQueue = DispatchQueue.main,
                               completion: @escaping (_ result: Result<[SMBVolume]>) -> Void) {
        let operation = BlockOperation()

        let blockOperation = {
            if operation.isCancelled {
                return
            }
            let requestResult = self.requestVolumes()

            completionQueue.async {
                completion(requestResult)
            }
        }
        operation.addExecutionBlock(blockOperation)
        self.dataQueue.addOperation(operation)
    }

    public func requestItems(fromVolume volume: SMBVolume, atPath path: String) -> Result<[SMBItem]> {
        let conError = self.attemptConnection()
        // switch result/error
        if let error = conError {
            return Result.failure(error)
        }

        var shareId: UInt16 = smb_tid.max
        smb_tree_connect(self.smbSession, volume.name.cString(using: .utf8), &shareId)
        if shareId == smb_tid.max {
            return Result.success([])
        }

        var relativePath = path // wildcard to search
        if relativePath.count > 0 {
            relativePath += "/*"
        } else {
            relativePath += "*"
        }
        relativePath = relativePath.replacingOccurrences(of: "/", with: "\\")

        // \SampleMedia\*
        let statList = smb_find(self.smbSession, shareId, relativePath.cString(using: .utf8))
        let listCount = smb_stat_list_count(statList)
        if listCount == 0 {
            return Result.success([])
        }

        var results: [SMBItem] = []

        var i = 0
        while i < listCount {
            let item = smb_stat_list_at(statList, i)
            guard let stat = item else { i = i + 1; continue }
            guard let smbItem = SMBItem(stat: stat, session: self, parentDirectoryFilePath: relativePath) else {
                i += 1
                continue
            }

            if smbItem.name.first != "." {
                results.append(smbItem)
            }

            i += 1
        }

        return Result.success(results)
    }

    public func requestItems(fromVolume volume: SMBVolume,
                             atPath path: String,
                             completionQueue: DispatchQueue = DispatchQueue.main,
                             completion: @escaping (_ result: Result<[SMBItem]>) -> Void) {
        let operation = BlockOperation()
        let blockOperation = {
            if operation.isCancelled {
                return
            }
            let requestResult = self.requestItems(fromVolume: volume, atPath: path)
            completionQueue.async {
                completion(requestResult)
            }
        }
        operation.addExecutionBlock(blockOperation)
        self.dataQueue.addOperation(operation)
    }

    public func attemptConnection() -> SMBSessionError? {
        var err: SMBSessionError?
        serialQueue.sync {
            err = self.attemptConnectionWithSessionPointer(smbSession: self.smbSession)
        }

        if err != nil {
            return err
        }

        self.sessionGuestState = SessionGuestState(rawValue: smb_session_is_guest(self.smbSession))

        return nil
    }

    internal func attemptConnectionWithSessionPointer(smbSession: OpaquePointer?) -> SMBSessionError? {

        // if we're connecting from a dowload task, and the sessions match, make sure to refresh them periodically
        if self.smbSession == smbSession {
            if let lrd = self.lastRequestDate {
                if Date().timeIntervalSince(lrd) > 60 {
                    smb_session_destroy(self.smbSession)
                    self.smbSession = smb_session_new()

                    self.connected = false
                }
            }
            self.lastRequestDate = Date()
        }

        // don't attempt another connection if already connected
        if smb_session_is_guest(smbSession) >= 0 {
            self.connected = true
            return nil
        }

        // ensure at least of piece of connection information is supplied
        if self.ipAddress == nil && self.hostName == nil {
            return SMBSessionError.unableToResolveAddress
        }

        // if only hostName or ipAddress are provided, use NetBIOS to resolve the other
        if let ipAddressChk = self.ipAddress {
            if ipAddressChk.characters.count == 0 {
                if self.hostName == nil {
                    let ns = NetBIOSNameService()
                    self.hostName = ns.networkNameFor(ipAddress: ipAddressChk)
                }
            }
        }
        if let hostName = self.hostName {
            if hostName.characters.count == 0 {
                if self.ipAddress == nil {
                    let ns = NetBIOSNameService()
                    self.ipAddress = ns.resolveIPAddress(forName: hostName, ofType: NetBIOSNameServiceType.fileServer)
                }
            }
        }

        // if there is still no IP address we're boned
        guard let ipAddress = self.ipAddress else {
            return SMBSessionError.unableToResolveAddress
        }
        if ipAddress.characters.count < 1 {
            return SMBSessionError.unableToResolveAddress
        }

        let addr = UnsafeMutablePointer<in_addr>.allocate(capacity: 1)
        inet_aton(ipAddress.cString(using: .ascii), &addr.pointee)

        // attempt a connection
        let connectionResult = smb_session_connect(smbSession, hostName?.cString(using: .utf8),
                                                   addr.pointee.s_addr, Int32(SMB_TRANSPORT_TCP))
        if connectionResult != 0 {
            return SMBSessionError.unableToConnect
        }

        let userName: String
        if let givenUserName = self.userName {
            userName = givenUserName
        } else {
            userName = " "
        }

        let password: String
        if let givenPassword = self.password {
            password = givenPassword
        } else {
            password = " "
        }

        smb_session_set_creds(smbSession, hostName!.cString(using: .utf8),
                              userName.cString(using: .utf8),
                              password.cString(using: .utf8))
        if smb_session_login(smbSession) != 0 {
            return SMBSessionError.authenticationFailed
        }

        if smbSession == self.smbSession {
            self.connected = true
        }

        return nil
    }

    public func downloadTaskForFile(atPath path: String,
                                    destinationPath: String?,
                                    delegate: SessionDownloadTaskDelegate?) -> SessionDownloadTask {
        let task = SessionDownloadTask(session: self,
                                       sourceFilePath: path,
                                       destinationFilePath: destinationPath,
                                       delegate: delegate)
        self.downloadTasks.append(task)
        return task
    }

    @discardableResult public func uploadTaskForFile(atPath path: String,
                                                     data: Data,
                                                     delegate: SessionUploadTaskDelegate?) -> SessionUploadTask {
        let task = SessionUploadTask(session: self, path: path, data: data)
        task.delegate = delegate
        self.uploadTasks.append(task)
        return task
    }

    func cancelAllRequests() {
        self.dataQueue.cancelAllOperations()
    }

    deinit {
        guard let s = self.smbSession else { return }
        smb_session_destroy(s)
    }
}

extension SMBSession {
    public enum SessionGuestState: Int32 {
        case guest = 1
        case user = 0
        case error = -1
    }

    public enum SMBSessionError: Error {
        case unableToResolveAddress
        case unableToConnect
        case authenticationFailed
    }
}

extension SMBSession: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "hostname : \(String(describing: self.hostName))\n" +
               "ipAddress : \(String(describing: self.ipAddress))\n" +
               "userName : \(String(describing: self.userName))\n" +
               "connected : \(self.connected)"
    }

}
