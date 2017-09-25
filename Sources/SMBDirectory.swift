//
//  SMBDirectory.swift
//  SMBClient
//
//  Created by Seth Faxon on 9/25/17.
//  Copyright © 2017 Filmic. All rights reserved.
//

import libdsm

// shareRoot, directory, file are different things
public struct SMBDirectory {
    public var name: String
    public var parentPath: String

    public var createdAt: Date?
    public var accessedAt: Date?
    public var writeAt: Date?
    public var modifiedAt: Date?

    init?(stat: OpaquePointer, session: SMBSession, parentDirectoryFilePath path: String) {
        guard let cName = smb_stat_name(stat) else { return nil }
        self.name = String(cString: cName)
        self.parentPath = path
    }

    public var fullPath: String {
        return "\(self.parentPath)/\(self.name)"
    }
}
