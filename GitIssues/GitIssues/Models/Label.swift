//
//  Label.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation

struct Label: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
    }
}
