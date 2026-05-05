//
//  Item.swift
//  tteona
//
//  Created by 이석태 on 5/5/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
