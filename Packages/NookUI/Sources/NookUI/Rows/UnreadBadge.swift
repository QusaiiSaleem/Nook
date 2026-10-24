// Licensed under GPL-3.0. See LICENSE.
//
//  UnreadBadge.swift
//  Nook
//
//  A page's unread count (`PageSession.unreadCount`) on a favorite tile or pinned row. Same look
//  as the URL bar's console error count: a white number on a red capsule.
//

import SwiftUI
import NookDesign

public struct UnreadBadge: View {
    let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(NookDesign.Font.micro.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, NookDesign.Spacing.xs)
            .background(Capsule().fill(NookDesign.Surface.danger))
            .accessibilityLabel("\(count)")
    }
}
