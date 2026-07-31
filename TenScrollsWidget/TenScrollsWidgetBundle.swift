//
//  TenScrollsWidgetBundle.swift
//  TenScrollsWidget
//
//  Created by eamon kendrick on 7/14/26.
//

import WidgetKit
import SwiftUI

@main
struct TenScrollsWidgetBundle: WidgetBundle {
    init() {
        // Surfaces a missing/mismatched App Group entitlement in the console
        // at launch, rather than as a silently-empty widget later — see
        // `WidgetStorage.logStartupDiagnostics`.
        WidgetStorage.logStartupDiagnostics(caller: "widget")
    }

    var body: some Widget {
        TenScrollsWidget()
        JournalWidget()
    }
}
