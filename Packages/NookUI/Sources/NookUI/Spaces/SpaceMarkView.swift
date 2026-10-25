// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceMarkView.swift
//  Nook
//
//  A space's mark at a given size: an emoji, or the small PNG drawn from the person's SVG when
//  they chose it (`SpaceMarkRenderer`). The PNG is decoded once and cached; one that does not
//  open shows as a plain dot, so a bad mark never leaves a gap in the switcher.
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
        case .picture(let png):
            if let image = Self.image(png) {
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

    private static let cache = NSCache<NSData, PlatformImage>()

    private static func image(_ png: Data) -> PlatformImage? {
        if let cached = cache.object(forKey: png as NSData) { return cached }
        guard let image = PlatformImage(data: png) else { return nil }
        cache.setObject(image, forKey: png as NSData)
        return image
    }
}
