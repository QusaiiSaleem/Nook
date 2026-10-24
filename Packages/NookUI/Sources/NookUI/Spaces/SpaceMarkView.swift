// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceMarkView.swift
//  Nook
//
//  A space's mark (an emoji, or a small SVG the person chose) at a given size. An SVG the system
//  cannot open shows as a plain dot, so a bad file never leaves a gap in the switcher.
//

import NookDesign
import NookTabsCore
import NookWeb
import SwiftUI

struct SpaceMarkView: View {
    let mark: SpaceMark
    let size: CGFloat

    var body: some View {
        switch mark {
        case .emoji(let text):
            Text(text).font(.system(size: size))
        case .svg(let data):
            if let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Circle()
                    .fill(.tertiary)
                    .frame(width: NookDesign.Spacing.sm, height: NookDesign.Spacing.sm)
            }
        }
    }
}
